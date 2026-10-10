#!/usr/bin/env python3
"""Initialize and plan one Terraform root, then emit a redacted change summary."""

from __future__ import annotations

import argparse
import json
import os
import subprocess
import sys
import tempfile
from pathlib import Path

from terraform_plan_summary import render_summary


BACKEND_CONFIGS = {
    "messaging": "environments/dev/backend.hcl",
    "redis": "environments/dev/backend.hcl",
}

VAR_FILES = {
    "messaging": "environments/dev/terraform.tfvars.example",
}


def run(root: str, *args: str, capture: bool = False) -> subprocess.CompletedProcess[str]:
    command = ["terraform", f"-chdir={root}", *args]
    result = subprocess.run(command, text=True, capture_output=capture, check=False)
    if result.returncode != 0:
        output = "\n".join(filter(None, [result.stdout, result.stderr]))
        if output:
            print(f"Command failed in {root}: {' '.join(command)}", file=sys.stderr)
            print("\n".join(output.splitlines()[-40:]), file=sys.stderr)
        raise subprocess.CalledProcessError(result.returncode, command)
    return result


def initialize(root: str) -> None:
    args = ["init", "-input=false", "-lockfile=readonly", "-reconfigure"]
    if root in BACKEND_CONFIGS:
        args.append(f"-backend-config={BACKEND_CONFIGS[root]}")
    run(root, *args, capture=True)


def prepare(root: str) -> None:
    run(root, "fmt", "-check", "-recursive")
    initialize(root)
    run(root, "validate", "-no-color")


def create_plan(root: str, plan_path: Path) -> dict:
    args = [
        "plan",
        "-input=false",
        "-lock-timeout=5m",
        "-no-color",
        f"-out={plan_path}",
    ]
    if root in VAR_FILES:
        args.append(f"-var-file={VAR_FILES[root]}")
    run(root, *args, capture=True)

    result = run(root, "show", "-json", str(plan_path), capture=True)
    return json.loads(result.stdout)


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("root")
    parser.add_argument("--summary", default="terraform-plan-summary.md")
    args = parser.parse_args()

    allowed_roots = {
        "app-server",
        "shared-infra",
        "test-infra",
        "messaging",
        "redis",
        "ai-server/infra",
        "ai-server/dev-infra",
        "ai-server/dashboard",
    }
    if args.root not in allowed_roots:
        raise SystemExit(f"unknown Terraform root: {args.root}")

    prepare(args.root)
    with tempfile.TemporaryDirectory(prefix="terraform-plan-") as temp_dir:
        plan_path = Path(temp_dir) / "tfplan"
        plan = create_plan(args.root, plan_path)
        summary = render_summary(plan, args.root, include_value_details=True)
        Path(args.summary).write_text(summary, encoding="utf-8")
        step_summary = os.environ.get("GITHUB_STEP_SUMMARY")
        if step_summary:
            with open(step_summary, "a", encoding="utf-8") as summary_file:
                summary_file.write(summary)
                summary_file.write("\n")
        print(summary, end="")


if __name__ == "__main__":
    main()
