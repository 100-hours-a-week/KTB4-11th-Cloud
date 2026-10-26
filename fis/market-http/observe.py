#!/usr/bin/env python3
"""Finite read-only ECS/ALB observer. Runs on the operator PC, not the load host."""
import argparse
import datetime as dt
import json
import time
from pathlib import Path

from preflight import CLUSTER, SERVICE, TG, aws


def snapshot(old_arn):
    services = aws("ecs", "describe-services", "--cluster", CLUSTER, "--services", SERVICE)
    if services.get("failures") or len(services.get("services", [])) != 1:
        raise ValueError("Cannot resolve market-http service")
    current = aws("ecs", "list-tasks", "--cluster", CLUSTER, "--service-name", SERVICE,
                  "--desired-status", "RUNNING")["taskArns"]
    arns = sorted(set(current + [old_arn]))
    tasks = aws("ecs", "describe-tasks", "--cluster", CLUSTER, "--tasks", *arns)
    targets = aws("elbv2", "describe-target-health", "--target-group-arn", TG)
    return {"observed_at": dt.datetime.now(dt.timezone.utc).isoformat(),
            "service": services["services"][0], "tasks": tasks,
            "targets": targets, "original_target": old_arn}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--task-arn", required=True)
    parser.add_argument("--seconds", type=int, default=1800)
    parser.add_argument("--interval", type=int, default=10)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    prefix = "arn:aws:ecs:ap-northeast-2:250832562715:task/" + CLUSTER + "/"
    if not args.task_arn.startswith(prefix):
        parser.error("Task must be in the approved cluster/account/region")
    if not 1 <= args.seconds <= 7200 or not 5 <= args.interval <= 60:
        parser.error("Use seconds=1..7200 and interval=5..60")
    args.output.parent.mkdir(parents=True, exist_ok=True)
    deadline = time.monotonic() + args.seconds
    # Exclusive creation preserves earlier evidence.
    with args.output.open("x", buffering=1) as out:
        while time.monotonic() < deadline:
            try:
                record = snapshot(args.task_arn)
            except Exception as exc:
                record = {"observed_at": dt.datetime.now(dt.timezone.utc).isoformat(),
                          "observation_error": str(exc)}
            out.write(json.dumps(record) + "\n")
            remaining = deadline - time.monotonic()
            if remaining > 0:
                time.sleep(min(args.interval, remaining))


if __name__ == "__main__":
    main()
