#!/usr/bin/env python3
"""Verify that ECS services completed deployment with active task definitions."""

from __future__ import annotations

import argparse
import json
import os
import subprocess
import sys
from pathlib import Path
from typing import Any


def run_aws(*args: str) -> str:
    result = subprocess.run(
        ["aws", *args],
        text=True,
        capture_output=True,
        check=False,
    )
    if result.returncode != 0:
        output = "\n".join(filter(None, [result.stdout, result.stderr]))
        if output:
            print(output, file=sys.stderr)
        raise subprocess.CalledProcessError(result.returncode, result.args)
    return result.stdout


def describe_services(region: str, cluster: str, services: list[str]) -> list[dict[str, Any]]:
    output = run_aws(
        "ecs",
        "describe-services",
        "--region",
        region,
        "--cluster",
        cluster,
        "--services",
        *services,
        "--output",
        "json",
    )
    response = json.loads(output)
    failures = response.get("failures", [])
    if failures:
        reasons = ", ".join(
            f"{failure.get('arn', 'unknown')}: {failure.get('reason', 'unknown')}"
            for failure in failures
        )
        raise RuntimeError(f"ECS service lookup failed: {reasons}")
    return response.get("services", [])


def task_definition_status(region: str, task_definition: str) -> str:
    output = run_aws(
        "ecs",
        "describe-task-definition",
        "--region",
        region,
        "--task-definition",
        task_definition,
        "--query",
        "taskDefinition.status",
        "--output",
        "text",
    )
    return output.strip()


def validate_service(service: dict[str, Any], task_status: str) -> list[str]:
    name = service.get("serviceName", "unknown")
    errors: list[str] = []

    if service.get("status") != "ACTIVE":
        errors.append(f"service status is {service.get('status')}, expected ACTIVE")

    desired = service.get("desiredCount", 0)
    running = service.get("runningCount", 0)
    pending = service.get("pendingCount", 0)
    if running != desired or pending != 0:
        errors.append(
            f"task counts are desired={desired}, running={running}, pending={pending}"
        )

    task_definition = service.get("taskDefinition", "")
    if task_status != "ACTIVE":
        errors.append(
            f"referenced task definition {task_definition} is {task_status}, expected ACTIVE"
        )

    primary = next(
        (
            deployment
            for deployment in service.get("deployments", [])
            if deployment.get("status") == "PRIMARY"
        ),
        None,
    )
    if primary is None:
        errors.append("PRIMARY deployment is missing")
    else:
        if primary.get("taskDefinition") != task_definition:
            errors.append(
                "PRIMARY deployment task definition does not match the service task definition"
            )
        if primary.get("rolloutState") != "COMPLETED":
            errors.append(
                f"PRIMARY rollout is {primary.get('rolloutState')}, expected COMPLETED"
            )

    return [f"{name}: {error}" for error in errors]


def append_summary(rows: list[tuple[str, str, int, int, int]]) -> None:
    summary_path = os.environ.get("GITHUB_STEP_SUMMARY")
    if not summary_path:
        return

    lines = [
        "## ECS deployment verification",
        "",
        "| Service | Task definition | Desired | Running | Pending |",
        "|---|---|---:|---:|---:|",
    ]
    lines.extend(
        f"| `{name}` | `{task_definition}` | {desired} | {running} | {pending} |"
        for name, task_definition, desired, running, pending in rows
    )
    lines.append("")
    with Path(summary_path).open("a", encoding="utf-8") as summary_file:
        summary_file.write("\n".join(lines))
        summary_file.write("\n")


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--region", required=True)
    parser.add_argument("--cluster", required=True)
    parser.add_argument("services", nargs="+")
    args = parser.parse_args()

    run_aws(
        "ecs",
        "wait",
        "services-stable",
        "--region",
        args.region,
        "--cluster",
        args.cluster,
        "--services",
        *args.services,
    )

    services = describe_services(args.region, args.cluster, args.services)
    found_names = {service.get("serviceName") for service in services}
    missing = sorted(set(args.services) - found_names)
    errors = [f"{name}: service was not returned by ECS" for name in missing]
    rows: list[tuple[str, str, int, int, int]] = []

    for service in services:
        task_definition = service.get("taskDefinition", "")
        status = task_definition_status(args.region, task_definition)
        errors.extend(validate_service(service, status))
        rows.append(
            (
                service.get("serviceName", "unknown"),
                task_definition.rsplit("/", 1)[-1],
                service.get("desiredCount", 0),
                service.get("runningCount", 0),
                service.get("pendingCount", 0),
            )
        )

    append_summary(rows)
    if errors:
        print("ECS deployment verification failed:", file=sys.stderr)
        for error in errors:
            print(f"- {error}", file=sys.stderr)
        raise SystemExit(1)

    for name, task_definition, desired, running, pending in rows:
        print(
            f"Verified {name}: taskDefinition={task_definition}, "
            f"desired={desired}, running={running}, pending={pending}"
        )


if __name__ == "__main__":
    main()
