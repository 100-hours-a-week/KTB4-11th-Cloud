#!/usr/bin/env python3
"""Record experiment markers or import k6 JSON points into CloudWatch Logs/EMF."""

from __future__ import annotations

import argparse
import json
import math
import subprocess
import sys
import tempfile
from datetime import datetime, timezone
from pathlib import Path

METRICS = {
    "http_reqs": ("Requests", "Count"),
    "http_req_failed": ("Failures", "Count"),
    "http_req_duration": ("RequestDurationMs", "Milliseconds"),
    "sse_connect_duration_ms": ("SSEConnectDurationMs", "Milliseconds"),
    "sse_event_gap_ms": ("SSEEventGapMs", "Milliseconds"),
    "sse_reconnects": ("SSEReconnects", "Count"),
}


def point_event(point: dict, service: str, scenario: str, test_id: str) -> dict | None:
    if point.get("type") != "Point" or point.get("metric") not in METRICS:
        return None
    data = point["data"]
    value = data["value"]
    if not isinstance(value, (int, float)) or not math.isfinite(value) or value < 0:
        raise ValueError("Metric values must be finite, non-negative numbers")
    instant = datetime.fromisoformat(data["time"].replace("Z", "+00:00"))
    if instant.tzinfo is None:
        raise ValueError("Metric timestamps must include a timezone")
    timestamp = int(instant.timestamp() * 1000)
    metric, unit = METRICS[point["metric"]]
    message = {
        "_aws": {
            "Timestamp": timestamp,
            "CloudWatchMetrics": [{
                "Namespace": "StockSpoon/Experiments",
                "Dimensions": [["ServiceName", "Scenario"]],
                "Metrics": [{"Name": metric, "Unit": unit}],
            }],
        },
        "TestId": test_id,
        "ServiceName": service,
        "Scenario": scenario,
        metric: value,
    }
    return {"timestamp": timestamp, "message": json.dumps(message, ensure_ascii=False)}


def send_batch(events: list[dict], args: argparse.Namespace) -> None:
    events.sort(key=lambda event: event["timestamp"])
    if args.dry_run:
        for event in events:
            print(event["message"])
        return
    payload = {
        "logGroupName": args.log_group,
        "logStreamName": args.test_id,
        "logEvents": events,
    }
    with tempfile.TemporaryDirectory(prefix="stockspoon-emf-") as folder:
        path = Path(folder) / "events.json"
        path.write_text(json.dumps(payload, ensure_ascii=False), encoding="utf-8")
        subprocess.run([
            "aws", "--profile", args.profile, "--region", args.region,
            "logs", "put-log-events", "--cli-input-json", f"file://{path}",
        ], check=True, capture_output=True, text=True)


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--profile", default="pattie_for_terraform")
    parser.add_argument("--region", default="ap-northeast-2")
    parser.add_argument("--log-group", default="/stockspoon/stockspoon-v2-prod/experiments")
    parser.add_argument("--test-id", required=True)
    parser.add_argument("--service", choices=["backend", "market-http"], required=True)
    parser.add_argument("--scenario", choices=["scaling", "migration", "fault"], required=True)
    parser.add_argument("--dry-run", action="store_true")
    commands = parser.add_subparsers(dest="command", required=True)
    marker = commands.add_parser("marker")
    marker.add_argument("--event", choices=["start", "end", "traffic-shift", "fault", "restore", "note"], required=True)
    marker.add_argument("--message", default="")
    ingest = commands.add_parser("import-k6")
    ingest.add_argument("--input", type=Path, required=True)
    args = parser.parse_args()
    if not args.test_id or len(args.test_id) > 100 or any(c in args.test_id for c in ":*\n\r"):
        parser.error("test-id must be 1-100 characters without colon, asterisk or newlines")

    if not args.dry_run:
        result = subprocess.run([
            "aws", "--profile", args.profile, "--region", args.region,
            "logs", "create-log-stream", "--log-group-name", args.log_group,
            "--log-stream-name", args.test_id,
        ], capture_output=True, text=True)
        if result.returncode and "ResourceAlreadyExistsException" not in result.stderr:
            raise RuntimeError(result.stderr.strip())

    if args.command == "marker":
        timestamp = int(datetime.now(timezone.utc).timestamp() * 1000)
        send_batch([{
            "timestamp": timestamp,
            "message": json.dumps({
                "TestId": args.test_id, "ServiceName": args.service,
                "Scenario": args.scenario, "Event": args.event, "Message": args.message,
            }, ensure_ascii=False),
        }], args)
        return

    # 각 원시 지연 표본을 발행한다. p95 값들의 평균을 전체 p95로 오인하지 않는다.
    batch = []
    uploaded = 0
    with args.input.open(encoding="utf-8") as source:
        for line_number, line in enumerate(source, 1):
            if not line.strip():
                continue
            try:
                event = point_event(json.loads(line), args.service, args.scenario, args.test_id)
            except (KeyError, TypeError, ValueError) as error:
                raise ValueError(f"Invalid k6 point at line {line_number}: {error}") from error
            if event is None:
                continue
            batch.append(event)
            if len(batch) == 100:
                send_batch(batch, args)
                uploaded += len(batch)
                batch = []
    if batch:
        send_batch(batch, args)
        uploaded += len(batch)
    print(f"Processed {uploaded} metric samples", file=sys.stderr)


if __name__ == "__main__":
    try:
        main()
    except subprocess.CalledProcessError as error:
        print(error.stderr or str(error), file=sys.stderr)
        raise SystemExit(1) from error
