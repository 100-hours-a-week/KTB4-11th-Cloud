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

from terraform_fis import FIS_ROOT, write_ci_variables
from terraform_plan_summary import render_summary
from terraform_roots import ROOT_ORDER, root_dir


# Keyed by root ID. Paths are relative to the root's Terraform directory.
BACKEND_CONFIGS = {
    "messaging": "environments/dev/backend.hcl",
    "messaging@prod": "environments/prod/backend.hcl",
    "redis": "environments/dev/backend.hcl",
    "redis@prod": "environments/prod/backend.hcl",
}

VAR_FILES = {
    "monitoring": "environments/prod/terraform.tfvars.example",
    "ecs": "environments/prod/terraform.tfvars.example",
    "messaging": "environments/dev/terraform.tfvars.example",
    "messaging@prod": "environments/prod/terraform.tfvars.example",
    "redis": "environments/dev/terraform.tfvars.example",
    "redis@prod": "environments/prod/terraform.tfvars.example",
    # S3에 배포된 중앙 모니터링 서버와 개발 연결을 CI에서도 유지한다.
    "monitoring": "development.tfvars.example",
}

MESSAGING_ROOTS = {"messaging", "messaging@prod"}
REPOSITORY_ROOT = Path(__file__).resolve().parents[2]


def run(root: str, *args: str, capture: bool = False) -> subprocess.CompletedProcess[str]:
    command = ["terraform", f"-chdir={root_dir(root)}", *args]
    print(f"[{root}] terraform {' '.join(args)}", flush=True)
    result = subprocess.run(command, text=True, capture_output=capture, check=False)
    if result.returncode != 0:
        output = "\n".join(filter(None, [result.stdout, result.stderr]))
        if output:
            print(f"Command failed in {root}: {' '.join(command)}", file=sys.stderr)
            print("\n".join(output.splitlines()[-40:]), file=sys.stderr)
        raise subprocess.CalledProcessError(result.returncode, command)
    return result


def build_local_artifacts(root: str) -> None:
    if root not in MESSAGING_ROOTS:
        return

    command = [
        "bash",
        str(REPOSITORY_ROOT / "messaging/lambda/build_db_write_replay_package.sh"),
    ]
    result = subprocess.run(command, cwd=REPOSITORY_ROOT, text=True, capture_output=True, check=False)
    output = "\n".join(filter(None, [result.stdout, result.stderr]))
    if result.returncode != 0:
        if output:
            print(f"Command failed while preparing artifacts for {root}: {' '.join(command)}", file=sys.stderr)
            print("\n".join(output.splitlines()[-40:]), file=sys.stderr)
        raise subprocess.CalledProcessError(result.returncode, command)
    if output:
        print(output, end="" if output.endswith("\n") else "\n")


def initialize(root: str) -> None:
    args = ["init", "-input=false", "-lockfile=readonly", "-reconfigure"]
    if root in BACKEND_CONFIGS:
        args.append(f"-backend-config={BACKEND_CONFIGS[root]}")
    run(root, *args, capture=True)


def prepare(root: str) -> None:
    run(root, "fmt", "-check", "-recursive")
    initialize(root)
    build_local_artifacts(root)
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
    if root == FIS_ROOT:
        args.append(f"-var-file={write_ci_variables(plan_path.parent)}")
    run(root, *args, capture=True)

    result = run(root, "show", "-json", str(plan_path), capture=True)
    return json.loads(result.stdout)


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("root")
    parser.add_argument("--summary", default="terraform-plan-summary.md")
    args = parser.parse_args()

    if args.root not in ROOT_ORDER:
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
