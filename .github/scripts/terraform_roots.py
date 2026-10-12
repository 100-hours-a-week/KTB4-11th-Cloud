#!/usr/bin/env python3
"""Find Terraform roots affected by changed paths, including remote-state consumers."""

from __future__ import annotations

import argparse
import json
from pathlib import PurePosixPath


# A root ID is a Terraform directory, optionally suffixed with "@<env>" when the
# same directory is planned and applied with another backend and var file.
# A bare directory name is that root's default (dev) environment.
ROOT_ORDER = [
    "shared-infra",
    "test-infra",
    "messaging",
    "messaging@prod",
    "ai-server/dev-infra",
    "redis",
    "app-server",
    "ecr",
    "ecs",
    "ai-server/infra",
    "ai-server/dashboard",
]

DEPENDENTS = {
    "shared-infra": {"app-server", "ai-server/infra", "ecs"},
    "app-server": {"ai-server/infra", "ecs"},
    "test-infra": {"redis", "ai-server/dev-infra"},
    "messaging": {"ai-server/dev-infra"},
    "ai-server/dev-infra": {"redis"},
    "ecr": {"ecs"},
}


def root_dir(root: str) -> str:
    """Return the Terraform directory for a root ID such as ``messaging@prod``."""
    return root.split("@", 1)[0]


def affected_roots(paths: list[str]) -> list[str]:
    selected: set[str] = set()

    for raw_path in paths:
        path = PurePosixPath(raw_path.strip())
        if not raw_path.strip() or path.name == ".DS_Store":
            continue
        if path.suffix.lower() in {".md", ".rst"}:
            continue

        normalized = path.as_posix()
        for root in ROOT_ORDER:
            directory = root_dir(root)
            # Every environment of a directory shares its code, so select them all.
            if normalized == directory or normalized.startswith(f"{directory}/"):
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
