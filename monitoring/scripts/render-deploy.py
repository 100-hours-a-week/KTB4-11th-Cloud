#!/usr/bin/env python3
"""Render a reviewable SSM SendCommand JSON payload; never deploy or apply."""

from __future__ import annotations

import argparse
import base64
import gzip
import io
import ipaddress
import json
from pathlib import Path
import re
import shlex
import subprocess
import tarfile
from urllib.parse import urlsplit


ROOT = Path(__file__).resolve().parents[1]


def checked_endpoint(value: str, port: int, path: str = "") -> str:
    parsed = urlsplit(value)
    address = ipaddress.ip_address(parsed.hostname or "")
    if (address.version != 4 or not address.is_private or parsed.scheme != "http"
            or parsed.port != port or parsed.path != path or parsed.query
            or parsed.fragment or parsed.username or parsed.password):
        raise ValueError(f"Expected a private HTTP endpoint on port {port}")
    return value


def otel_environment(endpoint: str, service: str, environment: str) -> str:
    return "\n".join([
        f"OTEL_EXPORTER_OTLP_ENDPOINT={checked_endpoint(endpoint, 4318)}",
        "OTEL_EXPORTER_OTLP_PROTOCOL=http/protobuf",
        f"OTEL_SERVICE_NAME={service}",
        f"OTEL_RESOURCE_ATTRIBUTES=deployment.environment.name={environment}",
        "OTEL_TRACES_EXPORTER=otlp",
        "OTEL_METRICS_EXPORTER=none",
        "OTEL_LOGS_EXPORTER=none",
        "",
    ])


def deployment_files(target: str, destination: dict) -> dict[str, bytes]:
    if target == "server":
        files = {
            "config/" + path.relative_to(ROOT / "config").as_posix(): path.read_bytes()
            for path in (ROOT / "config").rglob("*") if path.is_file()
        }
        files["smoke.py"] = (ROOT / "scripts" / "smoke.py").read_bytes()
        address = ipaddress.IPv4Address(destination["private_ip"])
        root_url = destination.get("grafana_url") or "http://localhost:13000/"
        parsed_root = urlsplit(root_url)
        if parsed_root.scheme not in ["https", "http"] or not parsed_root.hostname:
            raise ValueError("Invalid Grafana root URL")
        values = {
            "COMPOSE_PROJECT_NAME": destination["compose_project_name"],
            "MONITORING_PRIVATE_IP": str(address),
            "AWS_REGION": destination["aws_region"],
            "LOKI_BUCKET": destination["loki_bucket"],
            "TEMPO_BUCKET": destination["tempo_bucket"],
            "GRAFANA_ROOT_URL": root_url,
            "GRAFANA_COOKIE_SECURE": str(parsed_root.scheme == "https").lower(),
        }
        if any(not re.fullmatch(r"[a-zA-Z0-9.:/_-]+", value) for value in values.values()):
            raise ValueError("Unexpected characters in the server environment")
        files["server.env"] = "".join(f"{key}={value}\n" for key, value in values.items()).encode()
    else:
        if destination.get("environment") != "dev" or destination.get("cluster") != "stockspoon-v2-dev":
            raise ValueError("The development payload must target the development stack")
        files = {"dev-agent/" + name: (ROOT / "dev-agent" / name).read_bytes()
                 for name in ["compose.yaml", "config.alloy"]}
        files["agent.env"] = (
            "LOKI_PUSH_URL=" + checked_endpoint(destination["loki_push_url"], 3100, "/loki/api/v1/push")
            + "\nPROMETHEUS_WRITE_URL=" + checked_endpoint(destination["prometheus_write_url"], 9090, "/api/v1/write")
            + "\n"
        ).encode()
        for service in ["backend", "frontend"]:
            files[f"{service}.otel.env"] = otel_environment(
                destination["otlp_http_endpoint"], service, "dev"
            ).encode()
    files["install.sh"] = (ROOT / "scripts" / "deploy" / f"{target}.sh").read_bytes()
    return files


def make_payload(target: str, outputs: dict) -> dict:
    output_name = "plg_tempo" if target == "server" else "development_telemetry"
    destination = outputs.get(output_name, {}).get("value")
    if not destination:
        raise ValueError(f"Enable and apply {output_name} before preparing this deployment")
    instance_id = destination["instance_id"]
    if not re.fullmatch(r"i-[0-9a-f]{8,17}", instance_id):
        raise ValueError("Invalid target instance ID")
    archive = io.BytesIO()
    with tarfile.open(fileobj=archive, mode="w") as tar:
        for name, content in sorted(deployment_files(target, destination).items()):
            info = tarfile.TarInfo(name)
            info.size, info.mode = len(content), 0o644
            tar.addfile(info, io.BytesIO(content))
    encoded = base64.b64encode(gzip.compress(archive.getvalue(), mtime=0)).decode()
    command = "\n".join([
        "#!/bin/bash", "set -Eeuo pipefail", "umask 077",
        "work_dir=$(mktemp -d)", "trap 'rm -rf \"$work_dir\"' EXIT",
        f"printf '%s' {shlex.quote(encoded)} | base64 -d | tar -xz -C \"$work_dir\"",
        'bash "$work_dir/install.sh"',
    ])
    if len(command.encode()) > 24000:
        raise ValueError("The bundle is too large for a single reviewed SSM payload")
    return {
        "DocumentName": "AWS-RunShellScript",
        "InstanceIds": [instance_id],
        "Comment": f"Deploy Stockspoon telemetry {target} configuration",
        "TimeoutSeconds": 600,
        "Parameters": {"commands": [command], "executionTimeout": ["600"]},
    }


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("target", choices=["server", "dev-agent"])
    parser.add_argument("--state-json", type=Path, help="Saved terraform output -json; optional for offline rendering")
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    if args.state_json:
        outputs = json.loads(args.state_json.read_text())
    else:
        result = subprocess.run(
            ["terraform", f"-chdir={ROOT}", "output", "-json"],
            check=True, text=True, capture_output=True,
        )
        outputs = json.loads(result.stdout)
    payload = make_payload(args.target, outputs)
    args.output.write_text(json.dumps(payload, ensure_ascii=False, indent=2) + "\n")
    args.output.chmod(0o600)
    print(f"Prepared {args.target} payload for {payload['InstanceIds'][0]}: {args.output}")
    print("No AWS command was submitted. No Terraform apply was executed.")


if __name__ == "__main__":
    main()
