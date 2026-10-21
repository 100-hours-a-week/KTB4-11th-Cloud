#!/usr/bin/env python3
"""Emit one synthetic OTLP/HTTP trace and verify lookup by its trace ID."""

import argparse
import json
import secrets
import time
import urllib.error
import urllib.request


def request_json(url, payload=None):
    data = None if payload is None else json.dumps(payload).encode()
    req = urllib.request.Request(
        url, data=data, headers={"Content-Type": "application/json", "Accept": "application/json"}
    )
    with urllib.request.urlopen(req, timeout=10) as response:
        return json.load(response)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--otlp", default="http://127.0.0.1:4318")
    parser.add_argument("--query", default="http://127.0.0.1:3200")
    args = parser.parse_args()
    trace_id, span_id = secrets.token_hex(16), secrets.token_hex(8)
    now = time.time_ns()
    payload = {
        "resourceSpans": [{
            "resource": {"attributes": [{
                "key": "service.name", "value": {"stringValue": "telemetry-smoke"}
            }]},
            "scopeSpans": [{
                "scope": {"name": "stockspoon-telemetry-smoke"},
                "spans": [{
                    "traceId": trace_id, "spanId": span_id,
                    "name": "telemetry-smoke", "kind": 2,
                    "startTimeUnixNano": str(now - 1_000_000),
                    "endTimeUnixNano": str(now), "status": {"code": 1},
                }],
            }],
        }],
    }
    result = request_json(args.otlp.rstrip("/") + "/v1/traces", payload)
    if result.get("partialSuccess", {}).get("rejectedSpans", 0) not in (0, "0"):
        raise SystemExit(f"Tempo rejected the test span: {result}")
    print(f"Sent trace {trace_id}; waiting for lookup", flush=True)
    for attempt in range(20):
        try:
            trace = request_json(args.query.rstrip("/") + "/api/traces/" + trace_id)
            if not (trace.get("batches") or trace.get("resourceSpans")):
                raise SystemExit("Lookup returned an empty trace")
            print(f"PASS: trace {trace_id} is queryable")
            return
        except urllib.error.HTTPError as error:
            if error.code != 404:
                raise
        if attempt < 19:
            time.sleep(2)
    raise SystemExit(f"Trace {trace_id} was accepted but not queryable within 40 seconds")


if __name__ == "__main__":
    main()
