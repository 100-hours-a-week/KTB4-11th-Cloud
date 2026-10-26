#!/usr/bin/env python3
"""Apply affected Terraform roots sequentially in remote-state dependency order."""

from __future__ import annotations

import json
import os
import subprocess
import sys
import tempfile
import time
from pathlib import Path

from terraform_plan import create_plan, prepare
from terraform_plan_summary import render_summary
from terraform_roots import ROOT_DEPENDENCIES, dependency_order, root_dir


def selected_roots(payload: str) -> list[str]:
    """잘못된 root 입력은 AWS 명령 실행 전에 거부한다."""
    selected = json.loads(payload)
    if not isinstance(selected, list) or not selected or any(not isinstance(root, str) for root in selected):
        raise ValueError("Terraform roots must be a non-empty JSON array of root names.")
    return dependency_order(ROOT_DEPENDENCIES, set(selected))


def main() -> None:
    if len(sys.argv) != 2:
        raise SystemExit("usage: terraform_apply.py '[\"shared-infra\", ...]' ")

    try:
        roots = selected_roots(sys.argv[1])
    except ValueError as error:
        raise SystemExit(str(error)) from error

    print(f"Apply order: {' -> '.join(roots)}", flush=True)

    summary_path = Path("terraform-apply-summary.md")
    summary_path.write_text("## Terraform apply\n\n", encoding="utf-8")
    step_summary = Path(os.environ["GITHUB_STEP_SUMMARY"])
    step_summary.write_text("## Terraform apply\n\n", encoding="utf-8")

    for root in roots:
        # Re-plan immediately before applying each root. This makes downstream
        # plans consume outputs from upstream states applied earlier in this run.
        started = time.monotonic()
        print(f"::group::Apply {root}", flush=True)
        try:
            prepare(root)
            with tempfile.TemporaryDirectory(prefix="terraform-apply-") as temp_dir:
                plan_path = Path(temp_dir) / "tfplan"
                plan = create_plan(root, plan_path)
                summary = render_summary(plan, root)
                with summary_path.open("a", encoding="utf-8") as summary_file:
                    summary_file.write(summary)
                    summary_file.write("\n")
                with step_summary.open("a", encoding="utf-8") as summary_file:
                    summary_file.write(summary)
                    summary_file.write("\n")

                # Terraform의 진행 상황과 오류를 즉시 job 로그에 전달한다.
                subprocess.run(
                    ["terraform", f"-chdir={root_dir(root)}", "apply", "-input=false", "-no-color", str(plan_path)],
                    text=True,
                    check=True,
                )
        except subprocess.CalledProcessError:
            print(f"Apply failed for {root}", file=sys.stderr, flush=True)
            failure = f"Apply failed for `{root}`. See this job's logs for the error.\n\n"
            with summary_path.open("a", encoding="utf-8") as summary_file:
                summary_file.write(failure)
            with step_summary.open("a", encoding="utf-8") as summary_file:
                summary_file.write(failure)
            raise
        finally:
            print(f"[{root}] elapsed: {time.monotonic() - started:.1f}s", flush=True)
            print("::endgroup::", flush=True)

        print(f"Apply completed: {root}", flush=True)
        with summary_path.open("a", encoding="utf-8") as summary_file:
            summary_file.write(f"Apply completed: `{root}`\n\n")
        with step_summary.open("a", encoding="utf-8") as summary_file:
            summary_file.write(f"Apply completed: `{root}`\n\n")


if __name__ == "__main__":
    main()
