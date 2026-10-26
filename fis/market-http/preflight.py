#!/usr/bin/env python3
"""Read-only AWS preflight. No start/stop/update/put API calls or client traffic."""
import argparse
import datetime as dt
import json
import re
import subprocess
from pathlib import Path

REGION = "ap-northeast-2"
ACCOUNT = "250832562715"
CLUSTER = "stockspoon-v2-prod-cluster"
SERVICE = "stockspoon-v2-prod-market-http"
TG = f"arn:aws:elasticloadbalancing:{REGION}:{ACCOUNT}:targetgroup/stockspoon-v2-prod-market-http/2a04e3ebb1d8697f"


def aws(service, action, *args):
    result = subprocess.run(
        ["aws", "--profile", "stockspoon", "--region", REGION, "--no-cli-pager",
         service, action, *args, "--output", "json"],
        check=True, capture_output=True, text=True, timeout=60)
    return json.loads(result.stdout)


def validate_snapshot(service, tasks, target_arn, targets, alarms):
    prefix = f"arn:aws:ecs:{REGION}:{ACCOUNT}:task/{CLUSTER}/"
    if not re.fullmatch(re.escape(prefix) + "[a-f0-9]{32}", target_arn):
        raise ValueError("Target is outside the approved cluster/account/region")
    if service.get("serviceName") != SERVICE or service.get("status") != "ACTIVE":
        raise ValueError("Wrong or inactive service")
    if (service.get("desiredCount"), service.get("runningCount"), service.get("pendingCount")) != (2, 2, 0):
        raise ValueError("Intraday experiment requires desired/running=2 and pending=0")
    deployments = service.get("deployments", [])
    if len(deployments) != 1 or deployments[0].get("rolloutState") != "COMPLETED":
        raise ValueError("Deployment is incomplete or overlapping")
    if len(tasks) != 2 or target_arn not in {t["taskArn"] for t in tasks}:
        raise ValueError("Target is not one of the two current service Tasks")
    task_ips = set()
    for task in tasks:
        if (task.get("group") != f"service:{SERVICE}"
                or task.get("lastStatus") != "RUNNING"
                or task.get("healthStatus") != "HEALTHY"
                or task.get("taskDefinitionArn") != service.get("taskDefinition")):
            raise ValueError("Task membership/status/definition is inconsistent")
        for attachment in task.get("attachments", []):
            for item in attachment.get("details", []):
                if item["name"] == "privateIPv4Address":
                    task_ips.add(item["value"])
    healthy_ips = {t["Target"]["Id"] for t in targets
                   if t["TargetHealth"]["State"] == "healthy"}
    if len(task_ips) != 2 or task_ips != healthy_ips or len(targets) != 2:
        raise ValueError("ALB healthy targets do not match both service Tasks")
    if not alarms or any(a.get("StateValue") != "OK" for a in alarms):
        raise ValueError("Every required stop alarm must exist and be OK")


def capture(target_arn, alarm_arns):
    identity = aws("sts", "get-caller-identity")
    if identity["Account"] != ACCOUNT:
        raise ValueError("Unexpected AWS account")
    services = aws("ecs", "describe-services", "--cluster", CLUSTER, "--services", SERVICE)
    if services.get("failures") or len(services.get("services", [])) != 1:
        raise ValueError("Cannot resolve service")
    task_arns = aws("ecs", "list-tasks", "--cluster", CLUSTER, "--service-name", SERVICE,
                    "--desired-status", "RUNNING")["taskArns"]
    if not task_arns:
        raise ValueError("Service has no running Tasks")
    described = aws("ecs", "describe-tasks", "--cluster", CLUSTER, "--tasks", *task_arns)
    if described.get("failures"):
        raise ValueError("Cannot resolve every Task")
    prefix = f"arn:aws:cloudwatch:{REGION}:{ACCOUNT}:alarm:"
    if not alarm_arns or any(not a.startswith(prefix) for a in alarm_arns):
        raise ValueError("Stop alarms must be in the approved account and region")
    response = aws("cloudwatch", "describe-alarms", "--alarm-names",
                   *[a[len(prefix):] for a in alarm_arns])
    alarms = response.get("MetricAlarms", []) + response.get("CompositeAlarms", [])
    if set(alarm_arns) != {a["AlarmArn"] for a in alarms}:
        raise ValueError("A requested stop alarm is missing")
    targets = aws("elbv2", "describe-target-health", "--target-group-arn", TG)["TargetHealthDescriptions"]
    validate_snapshot(services["services"][0], described["tasks"], target_arn, targets, alarms)
    return {"captured_at": dt.datetime.now(dt.timezone.utc).isoformat(),
            "scope": "infrastructure preflight only; not authorization to inject faults",
            "service": services["services"][0], "tasks": described["tasks"],
            "targets": targets, "alarms": alarms, "target_task_arn": target_arn}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--task-arn", required=True)
    parser.add_argument("--stop-alarm-arn", action="append", required=True)
    parser.add_argument("--output", type=Path, required=True,
                        help="New directory for timestamped snapshot and Terraform variables")
    args = parser.parse_args()
    if args.output.exists():
        parser.error("Output path already exists; preserve previous snapshots")
    snapshot = capture(args.task_arn, args.stop_alarm_arn)
    args.output.mkdir(parents=True)
    (args.output / "snapshot.json").write_text(json.dumps(snapshot, indent=2) + "\n")
    (args.output / "target.tfvars.json").write_text(json.dumps({
        "target_task_arn": args.task_arn, "stop_alarm_arns": args.stop_alarm_arn}, indent=2) + "\n")
    print(json.dumps({"result": "INFRASTRUCTURE_CHECKED", "output": str(args.output),
                      "remaining": "input/client baseline, observability and stop-path checks"}))


if __name__ == "__main__":
    main()
