#!/usr/bin/env python3
"""마지막 성공한 CD 이후의 변경을 계산해 취소·실패한 실행의 변경도 포함한다."""

from __future__ import annotations

import argparse
import re
import subprocess
from pathlib import Path


def git(repository: Path, *args: str) -> subprocess.CompletedProcess[str]:
    return subprocess.run(["git", *args], cwd=repository, text=True, capture_output=True, check=False)


def changed_paths(base: str, head: str, repository: Path = Path(".")) -> list[str]:
    for revision in [base, head]:
        if revision and not re.fullmatch(r"(?:[0-9a-f]{40}|[0-9a-f]{64})", revision):
            raise ValueError("Terraform change detection requires full commit SHAs.")
    if not head:
        raise ValueError("The current commit SHA is required.")
    if git(repository, "cat-file", "-e", f"{head}^{{commit}}").returncode != 0:
        raise ValueError("The current commit is not present in the checkout.")

    command = ("ls-files",)
    if base and git(repository, "cat-file", "-e", f"{base}^{{commit}}").returncode == 0:
        # 최신 배포보다 오래된 커밋의 재실행은 인프라를 되돌리지 않는다.
        stale = git(repository, "merge-base", "--is-ancestor", head, base)
        if stale.returncode == 0:
            return []
        if stale.returncode != 1:
            raise RuntimeError(stale.stderr.strip())

        ancestor = git(repository, "merge-base", "--is-ancestor", base, head)
        if ancestor.returncode == 0:
            command = ("diff", "--name-only", "--no-renames", base, head)
        elif ancestor.returncode != 1:
            raise RuntimeError(ancestor.stderr.strip())
        # 첫 실행, 존재하지 않는 기준 커밋, main 이력 재작성은 전체를 검사한다.

    result = git(repository, *command)
    result.check_returncode()
    return result.stdout.splitlines()


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--base", default="")
    parser.add_argument("--head", required=True)
    parser.add_argument("--output", default="changed-paths.txt")
    args = parser.parse_args()
    paths = changed_paths(args.base, args.head)
    Path(args.output).write_text("".join(f"{path}\n" for path in paths), encoding="utf-8")
    print(f"Terraform change baseline: {args.base or '(initial deployment)'}; changed paths: {len(paths)}", flush=True)


if __name__ == "__main__":
    main()
