"""Resolve deployment inputs using CI credentials; never start an experiment."""
from __future__ import annotations

import json
from pathlib import Path
import re
import subprocess

FIS_ROOT = "fis/market-http/terraform"
ACCOUNT = "250832562715"
REGION = "ap-northeast-2"
CLUSTER = "stockspoon-v2-prod-cluster"
CLUSTER_ARN = f"arn:aws:ecs:{REGION}:{ACCOUNT}:cluster/{CLUSTER}"
SERVICE = "stockspoon-v2-prod-market-http"
TASK_PATTERN = rf"arn:aws:ecs:{REGION}:{ACCOUNT}:task/{CLUSTER}/[a-f0-9]{{32}}"
ALARM_NAMES = [
    "stockspoon-v2-prod-market-http-no-healthy-targets",
    "stockspoon-v2-prod-market-http-target-5xx-rate",
]


def aws(*args: str) -> dict:
    result = subprocess.run(
        ["aws", *args, "--region", REGION, "--output", "json", "--no-cli-pager"],
        text=True, capture_output=True, check=True,
    )
    return json.loads(result.stdout)


def resolve_ci_variables() -> dict:
    if aws("sts", "get-caller-identity").get("Account") != ACCOUNT:
        raise ValueError("FIS deployment requires the approved AWS account")
    listed = aws("ecs", "list-tasks", "--cluster", CLUSTER,
                 "--service-name", SERVICE, "--desired-status", "RUNNING").get("taskArns", [])
    if not listed or any(not re.fullmatch(TASK_PATTERN, arn) for arn in listed):
        raise ValueError("No valid running market-http Task candidates")
    # DescribeTasks accepts at most 100 ARNs. A single verified candidate suffices.
    selected = sorted(listed)[0]
    described = aws("ecs", "describe-tasks", "--cluster", CLUSTER, "--tasks", selected)
    tasks = described.get("tasks", [])
    if described.get("failures") or len(tasks) != 1:
        raise ValueError("Unable to verify selected market-http Task")
    task = tasks[0]
    if (task.get("taskArn") != selected or task.get("clusterArn") != CLUSTER_ARN
            or task.get("group") != f"service:{SERVICE}"
            or task.get("lastStatus") != "RUNNING" or task.get("desiredStatus") != "RUNNING"):
        raise ValueError("Selected Task must be running in the approved market-http service")
    alarms = aws("cloudwatch", "describe-alarms", "--alarm-names", *ALARM_NAMES)
    expected = {f"arn:aws:cloudwatch:{REGION}:{ACCOUNT}:alarm:{name}" for name in ALARM_NAMES}
    found = {alarm.get("AlarmArn") for alarm in alarms.get("MetricAlarms", [])}
    if found != expected:
        raise ValueError("Both configured FIS stop alarms must exist in the approved account")
    return {
        "use_ci_credentials": True,
        "deployment_profile": None,
        "target_task_arn": selected,
        "stop_alarm_arns": sorted(expected),
    }


def write_ci_variables(directory: Path) -> Path:
    variables = resolve_ci_variables()
    path = directory / "fis-ci.tfvars.json"
    path.touch(mode=0o600, exist_ok=False)
    path.write_text(json.dumps(variables), encoding="utf-8")
    return path.resolve()
