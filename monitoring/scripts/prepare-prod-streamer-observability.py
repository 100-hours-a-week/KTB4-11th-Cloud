#!/usr/bin/env python3
"""Render an AI EC2-only SSM patch; do not send or execute it."""

import argparse
import base64
import hashlib
import ipaddress
import json
from pathlib import Path
import re
from urllib.parse import urlsplit

ROOT = Path(__file__).resolve().parents[1]
INSTANCE = "i-04ab95c711878616c"


def payload(endpoint, alloy_sha256):
    parsed = urlsplit(endpoint)
    if (parsed.scheme != "http" or parsed.port != 4318 or parsed.path not in ["", "/"]
            or parsed.username or parsed.password or parsed.query or parsed.fragment
            or not ipaddress.IPv4Address(parsed.hostname).is_private):
        raise ValueError("Expected the private Tempo OTLP HTTP endpoint on port 4318")
    if not re.fullmatch(r"[0-9a-f]{64}", alloy_sha256):
        raise ValueError("Expected the live Alloy SHA256")
    override = (ROOT / "ai-agent/compose.prod-ai-metrics.yaml").read_text().replace(
        "${STREAMER_OTLP_ENDPOINT:?set STREAMER_OTLP_ENDPOINT}", endpoint.rstrip("/")
    )
    files = {
        "streamer-observability.yaml": override.encode(),
        "streamer-metrics.alloy": ("\n" + (ROOT / "ai-agent/streamer-metrics.alloy").read_text()
                                    .replace("__STREAMER_METRICS_PORT__", "9102")).encode(),
        "install.sh": (ROOT / "scripts/deploy/prod-streamer-observability.sh").read_bytes(),
    }
    fingerprint = hashlib.sha256(b"".join(files.values())).hexdigest()[:16]
    directory = "/tmp/stockspoon-streamer-observability-" + fingerprint
    commands = ["set -eu", f"install -d -m 0700 {directory}"]
    for name, content in files.items():
        encoded = base64.b64encode(content).decode()
        commands.append(f"printf '%s' '{encoded}' | base64 -d > {directory}/{name}")
    commands.append(f"EXPECTED_ALLOY_SHA256={alloy_sha256} bash {directory}/install.sh")
    return {"DocumentName": "AWS-RunShellScript", "InstanceIds": [INSTANCE],
            "Comment": "AI EC2 streamer observability only; no DB, ECS or ASG deployment",
            "Parameters": {"commands": commands}}


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--endpoint", required=True)
    parser.add_argument("--alloy-sha256", required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    args.output.write_text(json.dumps(payload(args.endpoint, args.alloy_sha256), indent=2) + "\n")
