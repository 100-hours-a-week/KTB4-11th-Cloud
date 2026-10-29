#!/usr/bin/env python3
"""Bounded manual replay recovery. Never delete, purge, or bypass a blocked message."""
import argparse
import json
from pathlib import Path
import subprocess
import time


COUNTERS = ("processed", "applied", "duplicates", "alreadySatisfied")


def drain(invoke, *, max_invocations=10, budget_seconds=1200, quiet_passes=2,
          retry_delay_seconds=2, clock=time.monotonic, sleep=time.sleep):
    if not 1 <= max_invocations <= 100 or not 1 <= quiet_passes <= 10:
        raise ValueError("Invalid invocation/quiet-pass limit")
    if not 70 < budget_seconds <= 7200 or not 0 <= retry_delay_seconds <= 60:
        raise ValueError("Invalid replay time budget")
    totals = dict.fromkeys(COUNTERS, 0)
    history = []
    quiet = 0
    started = clock()

    def finish(status, **details):
        return {"status": status, "drainComplete": status == "queue_empty", **totals,
                "invocations": len(history), "quietPasses": quiet,
                "elapsedSeconds": round(clock() - started, 3), "attempts": history, **details}

    for attempt in range(1, max_invocations + 1):
        remaining = int(budget_seconds - (clock() - started))
        if remaining <= 70:
            return finish("recovery_budget_exhausted")
        try:
            result = invoke(attempt, min(840, remaining))
        except Exception as error:
            # A timed-out invoke may still be running. Do not start another consumer blindly.
            history.append({"status": "invocation_unconfirmed", "errorType": type(error).__name__})
            return finish("invocation_unconfirmed", errorType=type(error).__name__)
        if (not isinstance(result, dict)
                or any(type(result.get(key)) is not int or result[key] < 0 for key in COUNTERS)
                or result["processed"] != sum(result[k] for k in COUNTERS[1:])):
            history.append({"status": "invalid_response"})
            return finish("invalid_response")
        history.append(result)
        for key in COUNTERS:
            totals[key] += result[key]
        status = result.get("status")
        if status == "queue_empty":
            # A later producer enqueue must be able to arrive between separate drains.
            quiet = 1 if result["processed"] else quiet + 1
            if quiet >= quiet_passes:
                return finish("queue_empty")
        elif status in ("message_limit", "runtime_limit"):
            quiet = 0
        elif (status == "blocked" and result.get("retryable") is True
              and result.get("releasedForRetry") is True):
            quiet = 0
        else:
            # Business conflicts/reconciliation failures stay at the FIFO head for diagnosis.
            return finish("blocked", lastResult=result)
        if attempt < max_invocations:
            sleep(retry_delay_seconds)
    return finish("recovery_invocation_limit")


def validate_options(options):
    name = options.get("function_name", "")
    if not isinstance(name, str) or not name.endswith("-db-write-replay-forwarder"):
        raise ValueError("function_name must identify the DB migration replay Lambda")
    maximum = options.get("max_messages", 100)
    if type(maximum) is not int or not 1 <= maximum <= 1000:
        raise ValueError("max_messages must be between 1 and 1000")
    for key, default, minimum, maximum in (("max_invocations", 10, 1, 100),
            ("quiet_passes", 2, 1, 10), ("budget_seconds", 1200, 71, 7200),
            ("retry_delay_seconds", 2, 0, 60)):
        value = options.get(key, default)
        if type(value) is not int or not minimum <= value <= maximum:
            raise ValueError(f"{key} must be between {minimum} and {maximum}")


def drain_aws(options, directory, region):
    validate_options(options)
    directory = Path(directory)
    directory.mkdir(parents=True, exist_ok=True)
    base = ["aws", "--region", region, "--no-cli-pager"]
    if options.get("profile"):
        base += ["--profile", options["profile"]]

    def invoke(attempt, runtime):
        response_file = directory / f"db-write-replay-response-{attempt}.json"
        with response_file.open("w") as stream:
            response_file.chmod(0o600)
        payload = {"maxMessages": options.get("max_messages", 100), "maxRuntimeSeconds": runtime}
        result = subprocess.run(base + ["lambda", "invoke", "--function-name", options["function_name"],
                "--invocation-type", "RequestResponse", "--cli-binary-format", "raw-in-base64-out",
                "--cli-connect-timeout", "10", "--cli-read-timeout", str(runtime + 20),
                "--payload", json.dumps(payload), str(response_file)],
                capture_output=True, text=True, check=True, timeout=runtime + 30)
        metadata = json.loads(result.stdout)
        if metadata.get("StatusCode") != 200 or metadata.get("FunctionError"):
            raise RuntimeError("Lambda did not return a confirmed drain result")
        return json.loads(response_file.read_text())

    result = drain(invoke, max_invocations=options.get("max_invocations", 10),
            budget_seconds=options.get("budget_seconds", 1200),
            quiet_passes=options.get("quiet_passes", 2),
            retry_delay_seconds=options.get("retry_delay_seconds", 2))
    summary = directory / "db-write-replay-recovery.json"
    summary.write_text(json.dumps(result, indent=2) + "\n")
    summary.chmod(0o600)
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--function-name", required=True)
    parser.add_argument("--region", default="ap-northeast-2")
    parser.add_argument("--profile")
    parser.add_argument("--out", required=True)
    parser.add_argument("--max-messages", type=int, default=100)
    parser.add_argument("--max-invocations", type=int, default=10)
    args = parser.parse_args()
    result = drain_aws(vars(args), args.out, args.region)
    print(json.dumps(result))
    return 0 if result["drainComplete"] else 2


if __name__ == "__main__":
    raise SystemExit(main())
