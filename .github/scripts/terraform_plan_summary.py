#!/usr/bin/env python3
"""Render Terraform resource actions and optionally detailed value changes."""

from __future__ import annotations

import html
import json
import re
import sys
from collections import Counter


ACTION_LABELS = {
    ("create",): "+ create",
    ("update",): "~ update",
    ("delete",): "- delete",
    ("delete", "create"): "-/+ replace",
    ("create", "delete"): "+/- replace",
}

_MISSING = object()
_UNKNOWN = object()
_IDENTIFIER = re.compile(r"^[A-Za-z_][A-Za-z0-9_]*$")


def _child_path(path: str, key: str | int) -> str:
    if isinstance(key, int):
        return f"{path}[{key}]"

    if _IDENTIFIER.fullmatch(key):
        return f"{path}.{key}" if path else key

    quoted_key = json.dumps(key, ensure_ascii=False)
    return f"{path}[{quoted_key}]" if path else f"[{quoted_key}]"


def _child_mask(mask: object, key: str | int) -> object:
    if isinstance(mask, dict):
        return mask.get(str(key))
    if isinstance(mask, list) and isinstance(key, int) and key < len(mask):
        return mask[key]
    return None


def _flatten_value(
    value: object,
    sensitive_mask: object,
    unknown_mask: object,
    path: str,
) -> dict[str, dict[str, object]]:
    if sensitive_mask is True:
        return {path: {"value": value, "sensitive": True}}
    if unknown_mask is True:
        return {path: {"value": _UNKNOWN, "unknown": True}}

    if isinstance(value, dict):
        if not value:
            return {path: {"value": value}}

        flattened: dict[str, dict[str, object]] = {}
        for key, child_value in value.items():
            child_path = _child_path(path, str(key))
            flattened.update(
                _flatten_value(
                    child_value,
                    _child_mask(sensitive_mask, str(key)),
                    _child_mask(unknown_mask, str(key)),
                    child_path,
                )
            )
        return flattened

    if isinstance(value, list):
        if not value:
            return {path: {"value": value}}

        flattened = {}
        for index, child_value in enumerate(value):
            flattened.update(
                _flatten_value(
                    child_value,
                    _child_mask(sensitive_mask, index),
                    _child_mask(unknown_mask, index),
                    _child_path(path, index),
                )
            )
        return flattened

    return {path: {"value": value}}


def _flatten_attributes(
    value: object,
    sensitive_mask: object,
    unknown_mask: object,
) -> dict[str, dict[str, object]]:
    if not isinstance(value, dict):
        return _flatten_value(value, sensitive_mask, unknown_mask, "(value)")

    flattened: dict[str, dict[str, object]] = {}
    for key, child_value in value.items():
        path = _child_path("", str(key))
        flattened.update(
            _flatten_value(
                child_value,
                _child_mask(sensitive_mask, str(key)),
                _child_mask(unknown_mask, str(key)),
                path,
            )
        )
    return flattened


def _entries_equal(before: object, after: object) -> bool:
    if before is _MISSING or after is _MISSING:
        return before is after

    if before.get("unknown") or after.get("unknown"):
        return bool(before.get("unknown") and after.get("unknown"))

    return before.get("value") == after.get("value")


def _changed_attributes(
    change: dict,
    actions: tuple[str, ...],
) -> list[tuple[str, object, object]]:
    before = _flatten_attributes(
        change.get("before"),
        change.get("before_sensitive"),
        None,
    )
    after = _flatten_attributes(
        change.get("after"),
        change.get("after_sensitive"),
        change.get("after_unknown"),
    )

    if actions == ("create",):
        return [(path, _MISSING, after[path]) for path in sorted(after)]
    if actions == ("delete",):
        return [(path, before[path], _MISSING) for path in sorted(before)]

    changed = []
    for path in sorted(set(before) | set(after)):
        before_entry = before.get(path, _MISSING)
        after_entry = after.get(path, _MISSING)
        if not _entries_equal(before_entry, after_entry):
            changed.append((path, before_entry, after_entry))
    return changed


def _json_value(value: object) -> str:
    return json.dumps(value, ensure_ascii=False, sort_keys=True, separators=(",", ":"))


def _value_pair(before: object, after: object) -> tuple[str, str]:
    before_sensitive = before is not _MISSING and bool(before.get("sensitive"))
    after_sensitive = after is not _MISSING and bool(after.get("sensitive"))

    if before is _MISSING:
        before_text = "미설정"
        if after_sensitive:
            after_text = "민감 값 설정됨 (내용 숨김)"
        elif after is not _MISSING and after.get("unknown"):
            after_text = "apply 후 계산"
        elif after is not _MISSING:
            after_text = _json_value(after.get("value"))
        else:
            after_text = "미설정"
        return before_text, after_text

    if after is _MISSING:
        if before_sensitive:
            return "민감 값 제거 예정 (내용 숨김)", "속성 제거됨"
        return _json_value(before.get("value")), "속성 제거됨"

    if before_sensitive or after_sensitive:
        before_text = "민감 값 숨김"
        if after.get("unknown"):
            after_text = "민감 값 (apply 후 계산, 내용 숨김)"
        else:
            after_text = "민감 값 변경됨 (내용 숨김)"
        return before_text, after_text

    before_text = "apply 후 계산" if before.get("unknown") else _json_value(before.get("value"))
    after_text = "apply 후 계산" if after.get("unknown") else _json_value(after.get("value"))
    return before_text, after_text


def _render_resource_change(change: dict, label: str) -> str:
    address = html.escape(str(change.get("address", "unknown")))
    actions = tuple(change.get("change", {}).get("actions", []))
    attributes = _changed_attributes(change.get("change", {}), actions)
    count = len(attributes)

    lines = [
        "<details>",
        f"<summary>{html.escape(label)} &nbsp; <code>{address}</code> · 속성 {count}개</summary>",
        "",
    ]

    if not attributes:
        lines.append("속성 수준의 변경값을 표시할 수 없습니다.")
    else:
        for path, before, after in attributes:
            before_text, after_text = _value_pair(before, after)
            lines.append(
                f"- <code>{html.escape(path)}</code>: "
                f"<code>{html.escape(before_text)}</code> → "
                f"<code>{html.escape(after_text)}</code>"
            )

    lines.extend(["", "</details>"])
    return "\n".join(lines)


def render_summary(plan: dict, root: str, include_value_details: bool = False) -> str:
    changes = []
    counts: Counter[str] = Counter()

    for resource_change in plan.get("resource_changes") or []:
        actions = tuple(resource_change.get("change", {}).get("actions", []))
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

        changes.append((resource_change, label))

    lines = [
        f"### Terraform plan: `{html.escape(root)}`",
        "",
        f"추가 **{counts['create']}** · 변경 **{counts['update']}** · 삭제 **{counts['delete']}** · 교체 **{counts['replace']}**",
        "",
    ]

    if not changes:
        lines.append("변경할 리소스가 없습니다.")
    elif include_value_details:
        for resource_change, label in changes:
            lines.append(_render_resource_change(resource_change, label))
            lines.append("")
    else:
        for resource_change, label in changes:
            address = html.escape(str(resource_change.get("address", "unknown")))
            lines.append(f"- `{label}` &nbsp; <code>{address}</code>")

    return "\n".join(lines).rstrip() + "\n"


def main() -> None:
    if len(sys.argv) != 3:
        raise SystemExit("usage: terraform_plan_summary.py plan.json root")

    with open(sys.argv[1], encoding="utf-8") as plan_file:
        plan = json.load(plan_file)
    sys.stdout.write(render_summary(plan, sys.argv[2], include_value_details=True))


if __name__ == "__main__":
    main()
