#!/usr/bin/env python3
"""Read-only V1 container preflight for conflicting off-hours order cancellation."""
import argparse
import inspect
import json
from pathlib import Path
import subprocess
import time


def inspect_archive(archive):
    import hashlib
    classes = [name for name in archive.namelist()
               if "river_be/" in name and name.endswith(("/OrderService.class", "/OrderSubscriptionService.class"))]
    if len(classes) != 2:
        return {"readyForOffHoursRehearsal": False, "status": "unverified_application_layout"}
    found = []
    fingerprints = {}
    for name in classes:
        data = archive.read(name)
        fingerprints[name] = hashlib.sha256(data).hexdigest()
        if b"cancelExpiredPendingOrders" in data:
            found.append(name)
    return {"readyForOffHoursRehearsal": not found,
            "status": "legacy_expiry_code_detected" if found else "legacy_expiry_code_absent",
            "legacyExpiryClasses": found, "classSha256": fingerprints}


def remote_program(container):
    return "\n".join([
        "import subprocess,tempfile,pathlib,zipfile,json",
        inspect.getsource(inspect_archive),
        f"container={container!r}",
        "metadata=json.loads(subprocess.run(['docker','inspect',container],capture_output=True,text=True,check=True).stdout)[0]",
        "summary={'container':container,'image':metadata['Config']['Image'],'startedAt':metadata['State']['StartedAt']}",
        "if not metadata['State']['Running']:",
        "    summary.update(status='backend_not_running',readyForOffHoursRehearsal=True)",
        "else:",
        "    with tempfile.TemporaryDirectory(prefix='stockspoon-policy-check-') as tmp:",
        "        jar=pathlib.Path(tmp)/'application.jar'",
        "        subprocess.run(['docker','cp',container+':/app/application.jar',str(jar)],capture_output=True,check=True)",
        "        with zipfile.ZipFile(jar) as archive: summary.update(inspect_archive(archive))",
        "print(json.dumps(summary))",
    ])


def check(instance_id, container, profile, region):
    base = ["aws", "--region", region, "--no-cli-pager"]
    if profile:
        base += ["--profile", profile]
    parameters = {"commands": ["python3 - <<'PY'\n" + remote_program(container) + "\nPY"],
                  "executionTimeout": ["45"]}
    response = subprocess.run(base + ["ssm", "send-command", "--instance-ids", instance_id,
            "--document-name", "AWS-RunShellScript", "--parameters", json.dumps(parameters), "--output", "json"],
            check=True, capture_output=True, text=True, timeout=20)
    command_id = json.loads(response.stdout)["Command"]["CommandId"]
    deadline = time.monotonic() + 60
    while time.monotonic() < deadline:
        response = subprocess.run(base + ["ssm", "get-command-invocation", "--command-id", command_id,
                "--instance-id", instance_id, "--output", "json"], capture_output=True, text=True, timeout=15)
        if response.returncode:
            # Newly created SSM invocations may not be visible on the first poll.
            time.sleep(1)
            continue
        invocation = json.loads(response.stdout)
        if invocation["Status"] == "Success":
            result = json.loads(invocation["StandardOutputContent"])
            return {"instanceId": instance_id, "commandId": command_id, **result}
        if invocation["Status"] not in ("Pending", "InProgress", "Delayed"):
            return {"instanceId": instance_id, "commandId": command_id,
                    "status": "verification_failed", "readyForOffHoursRehearsal": False}
        time.sleep(1)
    return {"instanceId": instance_id, "commandId": command_id,
            "status": "verification_timeout", "readyForOffHoursRehearsal": False}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--instance-id", required=True)
    parser.add_argument("--container", default="backend")
    parser.add_argument("--profile")
    parser.add_argument("--region", default="ap-northeast-2")
    parser.add_argument("--out", required=True)
    args = parser.parse_args()
    result = check(args.instance_id, args.container, args.profile, args.region)
    path = Path(args.out)
    path.write_text(json.dumps(result, indent=2) + "\n")
    path.chmod(0o600)
    print(json.dumps(result))
    return 0 if result["readyForOffHoursRehearsal"] else 2


if __name__ == "__main__":
    raise SystemExit(main())
