#!/usr/bin/env python3
"""Find Terraform roots affected by changed paths, including remote-state consumers."""

from __future__ import annotations

import argparse
import json
from pathlib import PurePosixPath


ROOT_ORDER = [
    "shared-infra",
    "test-infra",
    "messaging",
    "redis",
    "app-server",
    "ai-server/infra",
    "ai-server/dev-infra",
    "ai-server/dashboard",
]

DEPENDENTS = {
    "shared-infra": {"app-server", "ai-server/infra"},
    "app-server": {"ai-server/infra"},
    "test-infra": {"redis", "ai-server/dev-infra"},
    "messaging": {"ai-server/dev-infra"},
}


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
            if normalized == root or normalized.startswith(f"{root}/"):
                selected.add(root)
                break

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

    matrix = {"include": [{"root": root} for root in roots]}
    print(f"matrix={json.dumps(matrix, separators=(',', ':'))}")
    print(f"roots={json.dumps(roots, separators=(',', ':'))}")
    print(f"has_roots={'true' if roots else 'false'}")


if __name__ == "__main__":
    main()
