#!/usr/bin/env python3
"""Apply affected Terraform roots sequentially in remote-state dependency order."""

from __future__ import annotations

import json
import os
import subprocess
import sys
import tempfile
from pathlib import Path

from terraform_plan import create_plan, prepare
from terraform_plan_summary import render_summary


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


def main() -> None:
    if len(sys.argv) != 2:
        raise SystemExit("usage: terraform_apply.py '[\"shared-infra\", ...]' ")

    selected = set(json.loads(sys.argv[1]))
    roots = [root for root in ROOT_ORDER if root in selected]
    if not roots:
        raise SystemExit("No Terraform roots selected for apply.")

    summary_path = Path("terraform-apply-summary.md")
    summary_path.write_text("## Terraform apply\n\n", encoding="utf-8")
    step_summary = Path(os.environ["GITHUB_STEP_SUMMARY"])
    step_summary.write_text("## Terraform apply\n\n", encoding="utf-8")

    for root in roots:
        # Re-plan immediately before applying each root. This makes downstream
        # plans consume outputs from upstream states applied earlier in this run.
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

            result = subprocess.run(
                ["terraform", f"-chdir={root}", "apply", "-input=false", "-no-color", str(plan_path)],
                text=True,
                capture_output=True,
                check=False,
            )
            if result.returncode != 0:
                output = "\n".join(filter(None, [result.stdout, result.stderr]))
                if output:
                    print(f"Apply failed for {root}:", file=sys.stderr)
                    print("\n".join(output.splitlines()[-40:]), file=sys.stderr)
                failure = f"Apply failed for `{root}`. See this job's logs for the error.\n\n"
                with summary_path.open("a", encoding="utf-8") as summary_file:
                    summary_file.write(failure)
                with step_summary.open("a", encoding="utf-8") as summary_file:
                    summary_file.write(failure)
                raise subprocess.CalledProcessError(result.returncode, result.args)

            print(f"Apply completed: {root}")
            with summary_path.open("a", encoding="utf-8") as summary_file:
                summary_file.write(f"Apply completed: `{root}`\n\n")
            with step_summary.open("a", encoding="utf-8") as summary_file:
                summary_file.write(f"Apply completed: `{root}`\n\n")


if __name__ == "__main__":
    main()
