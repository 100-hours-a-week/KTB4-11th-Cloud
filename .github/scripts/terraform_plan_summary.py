#!/usr/bin/env python3
"""Render a value-free summary of Terraform resource actions."""

from __future__ import annotations

import html
import json
import sys
from collections import Counter


ACTION_LABELS = {
    ("create",): "+ create",
    ("update",): "~ update",
    ("delete",): "- delete",
    ("delete", "create"): "-/+ replace",
    ("create", "delete"): "+/- replace",
}


def render_summary(plan: dict, root: str) -> str:
    changes = []
    counts: Counter[str] = Counter()

    for change in plan.get("resource_changes") or []:
        actions = tuple(change.get("change", {}).get("actions", []))
        label = ACTION_LABELS.get(actions)
        if label is None:
            continue

        if actions == ("create",):
            counts["create"] += 1
        elif actions == ("update",):
            counts["update"] += 1
        elif actions == ("delete",):
            counts["delete"] += 1
        else:
            counts["replace"] += 1

        address = html.escape(str(change.get("address", "unknown")))
        changes.append(f"- `{label}` &nbsp; <code>{address}</code>")

    lines = [
        f"### Terraform plan: `{html.escape(root)}`",
        "",
        f"추가 **{counts['create']}** · 변경 **{counts['update']}** · 삭제 **{counts['delete']}** · 교체 **{counts['replace']}**",
        "",
    ]
    lines.extend(changes or ["변경할 리소스가 없습니다."])
    return "\n".join(lines) + "\n"


def main() -> None:
    if len(sys.argv) != 3:
        raise SystemExit("usage: terraform_plan_summary.py plan.json root")

    with open(sys.argv[1], encoding="utf-8") as plan_file:
        plan = json.load(plan_file)
    sys.stdout.write(render_summary(plan, sys.argv[2]))


if __name__ == "__main__":
    main()
