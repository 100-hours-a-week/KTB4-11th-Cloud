#!/usr/bin/env python3
"""Find Terraform roots affected by changed paths, including remote-state consumers."""

from __future__ import annotations

import argparse
import json
from graphlib import CycleError, TopologicalSorter
from pathlib import PurePosixPath


# A root ID is a Terraform directory, optionally suffixed with "@<env>" when the
# same directory is planned and applied with another backend and var file.
# A bare directory name is that root's default (dev) environment.
ROOT_DEPENDENCIES = {
    "shared-infra": set(),
    "test-infra": set(),
    "test-infra/sse-k6": {"test-infra"},
    "storage": set(),
    "ecr": set(),
    "ai-server/dashboard": set(),
    # 이름으로 참조하는 버킷·이미지 저장소도 기존 배포 의존성에 포함한다.
    "iam": {"storage"},
    "app-server": {"shared-infra", "ecr"},
    "messaging": {"shared-infra"},
    "messaging@prod": {"shared-infra"},
    "ai-server/dev-infra": {"test-infra", "messaging"},
    "redis": {"test-infra", "ai-server/dev-infra"},
    "redis@prod": {"shared-infra"},
    "ai-server/infra": {"shared-infra", "app-server", "redis@prod", "messaging@prod"},
    # 선택 기능의 state 참조도 포함해 기능 활성화 시 적용 순서를 보장한다.
    "monitoring": {
        "shared-infra", "app-server", "test-infra",
        "ai-server/dev-infra", "ai-server/infra",
    },
    "ecs": {
        "shared-infra", "app-server", "ecr", "redis@prod",
        "messaging@prod", "ai-server/infra", "monitoring",
    },
}

MODULE_CONSUMERS = {
    "modules/terraform-ci-policies": {"app-server"},
}


def dependency_order(
    dependencies: dict[str, set[str]], selected: set[str] | None = None,
) -> list[str]:
    """전체 그래프를 검증하고 선택된 root만 안정적인 위상 순서로 반환한다."""
    known = set(dependencies)
    unknown = set().union(*dependencies.values()) - known if dependencies else set()
    if selected is not None:
        unknown.update(selected - known)
    if unknown:
        raise ValueError(f"unknown Terraform roots: {', '.join(sorted(unknown))}")

    sorter = TopologicalSorter({root: sorted(dependencies[root]) for root in sorted(known)})
    try:
        sorter.prepare()
    except CycleError as error:
        raise ValueError(f"Terraform root dependency cycle: {' -> '.join(error.args[1])}") from error

    ordered = []
    while sorter.is_active():
        ready = sorted(sorter.get_ready())
        ordered.extend(ready)
        sorter.done(*ready)
    return ordered if selected is None else [root for root in ordered if root in selected]


# 영향 범위와 적용 순서는 같은 정의에서 도출한다.
ROOT_ORDER = dependency_order(ROOT_DEPENDENCIES)
DEPENDENTS = {root: set() for root in ROOT_DEPENDENCIES}
for _consumer, _dependencies in ROOT_DEPENDENCIES.items():
    for _dependency in _dependencies:
        DEPENDENTS[_dependency].add(_consumer)


def root_dir(root: str) -> str:
    """Return the Terraform directory for a root ID such as ``messaging@prod``."""
    return root.split("@", 1)[0]


def changes_workflow(path: PurePosixPath) -> bool:
    """배포 도구 변경 시 전체 root를 검증한다. 일반 인프라 변경은 확장하지 않는다."""
    return (
        path.as_posix() in {
            ".github/workflows/terraform-plan.yml",
            ".github/workflows/terraform-apply.yml",
        }
        or (path.parent.as_posix() == ".github/scripts"
            and path.name.startswith("terraform_") and path.suffix == ".py")
    )


def affected_roots(paths: list[str]) -> list[str]:
    selected: set[str] = set()

    for raw_path in paths:
        path = PurePosixPath(raw_path.strip())
        if not raw_path.strip() or path.name == ".DS_Store":
            continue
        if path.suffix.lower() in {".md", ".rst"}:
            continue

        if changes_workflow(path):
            return ROOT_ORDER.copy()

        normalized = path.as_posix()
        for module, consumers in MODULE_CONSUMERS.items():
            if normalized == module or normalized.startswith(f"{module}/"):
                selected.update(consumers)
        matching_directories = [
            root_dir(root) for root in ROOT_ORDER
            if normalized == root_dir(root) or normalized.startswith(f"{root_dir(root)}/")
        ]
        closest_directory = max(matching_directories, key=len, default=None)
        for root in ROOT_ORDER:
            directory = root_dir(root)
            if directory == closest_directory:
                relative = path.relative_to(directory)
                if relative.parts[:1] == ("environments",) and len(relative.parts) >= 2:
                    environments = {
                        candidate.split("@", 1)[1] if "@" in candidate else "dev"
                        for candidate in ROOT_ORDER if root_dir(candidate) == directory
                    }
                    if relative.parts[1] not in environments:
                        raise ValueError(f"unknown Terraform environment: {directory}/{relative.parts[1]}")
                    environment = root.split("@", 1)[1] if "@" in root else "dev"
                    if relative.parts[1] != environment:
                        continue
                selected.add(root)

    pending = list(selected)
    while pending:
        current = pending.pop()
        for dependent in DEPENDENTS.get(current, set()):
            if dependent not in selected:
                selected.add(dependent)
                pending.append(dependent)

    return [root for root in ROOT_ORDER if root in selected]


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("changed_paths")
    parser.add_argument(
        "--all-if-affected",
        action="store_true",
        help="select every root when any Terraform root changed",
    )
    args = parser.parse_args()

    with open(args.changed_paths, encoding="utf-8") as changed_file:
        paths = changed_file.readlines()

    roots = affected_roots(paths)
    if args.all_if_affected and roots:
        roots = ROOT_ORDER.copy()

    matrix = {"include": [{"root": root, "dir": root_dir(root)} for root in roots]}
    print(f"matrix={json.dumps(matrix, separators=(',', ':'))}")
    print(f"roots={json.dumps(roots, separators=(',', ':'))}")
    print(f"has_roots={'true' if roots else 'false'}")


if __name__ == "__main__":
    main()
