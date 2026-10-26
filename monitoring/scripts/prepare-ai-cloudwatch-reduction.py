#!/usr/bin/env python3
"""Prepare ai-v1 metric reduction; live apply requires an explicit flag on ai-v1."""
import argparse
import copy
import datetime as dt
import json
import os
from pathlib import Path
import subprocess
import urllib.request

CONTROL = "/opt/aws/amazon-cloudwatch-agent/bin/amazon-cloudwatch-agent-ctl"
CONFIG_DIR = Path("/opt/aws/amazon-cloudwatch-agent/etc")
CANONICAL = CONFIG_DIR / "stockspoon-ai-cloudwatch-agent.json"


def reduce_config(current):
    result = copy.deepcopy(current)
    metrics = result.get("metrics", {})
    if metrics.get("namespace") != "AI_CWAgent":
        raise ValueError("Only the AI_CWAgent namespace is allowed")
    if metrics.get("aggregation_dimensions"):
        raise ValueError("Review existing rollups before changing metric identities")
    dimensions = metrics.get("append_dimensions", {})
    if set(dimensions) != {"InstanceId", "InstanceType"}:
        raise ValueError("Unexpected dimensions; preserve alarm identities by explicit review")
    metrics["metrics_collected"] = {
        "cpu": {"measurement": ["usage_active"], "totalcpu": True},
        "mem": {"measurement": ["used_percent", "available_percent"]},
        "disk": {"resources": ["/"], "measurement": ["used_percent"], "drop_device": True},
    }
    # Top-level logs/traces/agent and existing dimensions are preserved.
    return result


def instance_id():
    request = urllib.request.Request("http://169.254.169.254/latest/api/token", method="PUT",
                                     headers={"X-aws-ec2-metadata-token-ttl-seconds": "60"})
    with urllib.request.urlopen(request, timeout=3) as response:
        token = response.read().decode()
    request = urllib.request.Request("http://169.254.169.254/latest/meta-data/instance-id",
                                     headers={"X-aws-ec2-metadata-token": token})
    with urllib.request.urlopen(request, timeout=3) as response:
        return response.read().decode()


def apply_on_ai(expected_instance):
    if os.geteuid() != 0:
        raise ValueError("Live apply must run as root on ai-v1")
    if expected_instance != "i-04ab95c711878616c" or instance_id() != expected_instance:
        raise ValueError("Wrong host; only the pre-approved ai-v1 instance is allowed")
    active = list((CONFIG_DIR / "amazon-cloudwatch-agent.d").glob("*.json"))
    if len(active) != 1:
        raise ValueError("Expected one active Agent config; do not overwrite merged configurations")
    old_bytes = active[0].read_bytes()
    current = json.loads(old_bytes)
    reduced = reduce_config(current)
    if current == reduced:
        print(json.dumps({"result": "UNCHANGED", "agent_restarted": False}))
        return
    backup = Path("/var/backups/stockspoon-cloudwatch") / dt.datetime.now(dt.timezone.utc).strftime("%Y%m%dT%H%M%S%fZ")
    backup.mkdir(parents=True, mode=0o700)
    (backup / "active-before.json").write_bytes(old_bytes)
    if CANONICAL.exists():
        (backup / "canonical-before.json").write_bytes(CANONICAL.read_bytes())
    CANONICAL.write_text(json.dumps(reduced, indent=2) + "\n")
    CANONICAL.chmod(0o600)
    command = [CONTROL, "-a", "fetch-config", "-m", "ec2", "-s", "-c", "file:" + str(CANONICAL)]
    try:
        subprocess.run(command, check=True, capture_output=True, text=True, timeout=120)
        status = subprocess.run([CONTROL, "-a", "status"], check=True,
                                capture_output=True, text=True, timeout=15)
        if json.loads(status.stdout).get("status") != "running":
            raise RuntimeError("CloudWatch Agent is not running after validation")
    except Exception:
        CANONICAL.write_bytes(old_bytes)
        subprocess.run(command, check=True, capture_output=True, text=True, timeout=120)
        raise RuntimeError("Reduction failed; previous Agent configuration restored") from None
    print(json.dumps({"result": "REDUCED", "backup": str(backup),
                      "kept_collectors": ["cpu", "mem", "disk"], "logs_preserved": True,
                      "application_containers_restarted": False}))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--input", type=Path, help="Downloaded active Agent JSON; never a fabricated replacement for its logs")
    parser.add_argument("--output", type=Path)
    parser.add_argument("--apply-on-ai-v1", action="store_true")
    parser.add_argument("--instance-id")
    args = parser.parse_args()
    if args.apply_on_ai_v1:
        if args.input or args.output or not args.instance_id:
            parser.error("Live mode requires only --apply-on-ai-v1 --instance-id")
        apply_on_ai(args.instance_id)
    else:
        if not args.input or not args.output or args.instance_id:
            parser.error("Offline mode requires --input and --output")
        current = json.loads(args.input.read_text())
        reduced = reduce_config(current)
        with args.output.open("x") as output:
            json.dump(reduced, output, indent=2)
            output.write("\n")
        args.output.chmod(0o600)
        print(json.dumps({"prepared": str(args.output), "removed_collectors":
                          sorted(set(current["metrics"]["metrics_collected"]) - {"cpu", "mem", "disk"}),
                          "deployed": False}))


if __name__ == "__main__":
    main()
