#!/usr/bin/env python3
"""Render telemetry SSM payloads or AI tracing env fragments; never deploy or apply."""

from __future__ import annotations

import argparse
import base64
import gzip
import lzma
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
AI_SERVICES = [
    "news-http", "portfolio-rebalancer", "report-builder", "news-preprocessor",
    "news-clusterer", "market-syncer", "news-graph-builder", "market-collector",
    "market-streamer", "portfolio-builder",
]
AI_TRACING_TARGETS = ["dev-ai-tracing", "prod-ai-tracing"]
MARKET_TRACING_TARGET = "prod-market-http-tracing"
METRICS_TARGETS = ["dev-ai-metrics", "prod-market-http-metrics"]
# Dashboards ship in their own SSM payload so neither command exceeds the limit.
SERVER_TARGETS = ["server", "server-dashboards"]
DASHBOARDS = ROOT / "config" / "grafana" / "dashboards"


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


def ai_tracing_endpoint(environment: str, outputs: dict) -> str:
    if environment not in ["dev", "prod"]:
        raise ValueError("Unknown AI environment")
    destination = (outputs.get("ai_telemetry", {}).get("value") or {}).get(environment)
    expected_cluster = "stockspoon-v2-dev" if environment == "dev" else "stockspoon-v1-ai"
    if not destination or destination.get("environment") != environment or destination.get("cluster") != expected_cluster:
        raise ValueError("AI tracing must use its own applied environment output")
    endpoint = destination.get("otlp_http_endpoint")
    if not endpoint:
        raise ValueError("Apply the monitoring AI Tempo output before preparing its environment")
    return checked_endpoint(endpoint, 4318)


def ai_tracing_environment(target: str, outputs: dict) -> str:
    if target not in AI_TRACING_TARGETS:
        raise ValueError("Select a development or production AI tracing target")
    environment = target.split("-", 1)[0]
    endpoint = ai_tracing_endpoint(environment, outputs)
    settings = {}
    for service in ["MARKET_STREAMER"] + (["MARKET_HTTP"] if environment == "dev" else []):
        settings.update({
            f"{service}_OTEL_SDK_DISABLED": "false",
            f"{service}_OTEL_EXPORTER_OTLP_ENDPOINT": endpoint,
            f"{service}_OTEL_TRACES_SAMPLER_ARG": "0.1" if service == "MARKET_STREAMER" else "0.01",
            f"{service}_OTEL_RESOURCE_ATTRIBUTES": f"deployment.environment.name={environment}",
        })
    if environment == "dev":
        settings["MARKET_HTTP_TRACE_SPANS_PER_SECOND"] = "100"
    return "".join(f"{key}={value}\n" for key, value in settings.items())


def market_http_tracing_environment(outputs: dict) -> dict[str, str]:
    settings = dict(line.split("=", 1) for line in otel_environment(
        ai_tracing_endpoint("prod", outputs), "market-http", "prod"
    ).splitlines())
    settings.update({
        "OTEL_SDK_DISABLED": "false",
        "OTEL_TRACES_SAMPLER": "parentbased_traceidratio",
        "OTEL_TRACES_SAMPLER_ARG": "0.01",
        "OTEL_PROPAGATORS": "none",
        "MARKET_HTTP_TRACE_SPANS_PER_SECOND": "100",
    })
    return settings


def market_http_metrics_environment(*, development: bool = False) -> dict[str, str]:
    settings = {
        "MARKET_HTTP_PROMETHEUS_BIND_HOST": "0.0.0.0",
        "MARKET_HTTP_PROMETHEUS_PORT": "9101",
    }
    if development:
        settings.update({"MARKET_STREAMER_PROMETHEUS_BIND_HOST": "0.0.0.0",
                         "MARKET_STREAMER_PROMETHEUS_PORT": "9102"})
    return settings


def config_bytes(path: Path) -> bytes:
    content = path.read_bytes()
    if path.suffix == ".json":
        return json.dumps(json.loads(content), ensure_ascii=False, separators=(",", ":")).encode()
    return content


def deployment_files(target: str, destination: dict, *, sse_prometheus: bool = False, streamer_metrics_port: int | None = None) -> dict[str, bytes]:
    if streamer_metrics_port is not None:
        if target not in ["dev-ai-agent", "prod-ai-agent"] or not 1024 <= streamer_metrics_port <= 65535 or streamer_metrics_port in [9101, 12345]:
            raise ValueError("Select an AI agent and a non-conflicting private streamer metrics port")
    if sse_prometheus and target not in [*SERVER_TARGETS, "dev-ai-agent"]:
        raise ValueError("SSE Prometheus is available only for server and dev-ai-agent deployments")
    if target == "server-dashboards":
        files = {
            "config/" + path.relative_to(ROOT / "config").as_posix(): config_bytes(path)
            for path in DASHBOARDS.rglob("*.json")
        }
    elif target == "server":
        files = {
            "config/" + path.relative_to(ROOT / "config").as_posix(): config_bytes(path)
            for path in (ROOT / "config").rglob("*")
            if path.is_file() and not path.name.endswith(".local.json")
            and DASHBOARDS not in path.parents
        }
        files["smoke.py"] = (ROOT / "scripts" / "smoke.py").read_bytes()
        files["configure-alerting.py"] = (ROOT / "scripts" / "configure-alerting.py").read_bytes()
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
    elif target in ["dev-ai-agent", "prod-ai-agent"]:
        environment = "dev" if target == "dev-ai-agent" else "prod"
        expected_cluster = "stockspoon-v2-dev" if environment == "dev" else "stockspoon-v1-ai"
        if destination.get("environment") != environment or destination.get("cluster") != expected_cluster:
            raise ValueError("AI agent environment and target must match")
        files = {"ai-agent/" + name: (ROOT / "ai-agent" / name).read_bytes()
                 for name in ["compose.yaml", "config.alloy"]}
        if sse_prometheus:
            files["ai-agent/config.alloy"] += (ROOT / "ai-agent/market-metrics.alloy").read_bytes()
        if streamer_metrics_port is not None:
            fragment = (ROOT / "ai-agent/streamer-metrics.alloy").read_text()
            files["ai-agent/config.alloy"] += fragment.replace("__STREAMER_METRICS_PORT__", str(streamer_metrics_port)).encode()
        services = AI_SERVICES + (["market-http"] if environment == "dev" else [])
        files["agent.env"] = (
            "LOKI_PUSH_URL=" + checked_endpoint(destination["loki_push_url"], 3100, "/loki/api/v1/push")
            + "\nPROMETHEUS_WRITE_URL=" + checked_endpoint(destination["prometheus_write_url"], 9090, "/api/v1/write")
            + f"\nDEPLOYMENT_ENVIRONMENT={environment}\nTELEMETRY_CLUSTER={expected_cluster}\n"
            + "AI_SERVICE_REGEX=" + "|".join(services) + "\n"
        ).encode()
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
    installer = "ai-agent" if target in ["dev-ai-agent", "prod-ai-agent"] else target
    if target not in SERVER_TARGETS:
        files["system-logs.sh"] = (ROOT / "scripts" / "deploy" / "system-logs.sh").read_bytes()
    files["install.sh"] = (ROOT / "scripts" / "deploy" / f"{installer}.sh").read_bytes()
    return files


def make_payload(target: str, outputs: dict, *, sse_prometheus: bool = False, streamer_metrics_port: int | None = None) -> dict:
    output_name = "plg_tempo" if target in SERVER_TARGETS else "development_telemetry"
    if target in ["dev-ai-agent", "prod-ai-agent"]:
        output_name = "ai_telemetry"
        environment = "dev" if target == "dev-ai-agent" else "prod"
        destination = (outputs.get(output_name, {}).get("value") or {}).get(environment)
    else:
        destination = outputs.get(output_name, {}).get("value")
    if not destination:
        raise ValueError(f"Enable and apply {output_name} before preparing this deployment")
    instance_id = destination["instance_id"]
    if not re.fullmatch(r"i-[0-9a-f]{8,17}", instance_id):
        raise ValueError("Invalid target instance ID")
    archive = io.BytesIO()
    with tarfile.open(fileobj=archive, mode="w") as tar:
        for name, content in sorted(deployment_files(target, destination, sse_prometheus=sse_prometheus, streamer_metrics_port=streamer_metrics_port).items(),
                                    key=lambda item: (not item[0].endswith(".py"), len(item[1]), item[0])):
            info = tarfile.TarInfo(name)
            info.size, info.mode = len(content), 0o644
            tar.addfile(info, io.BytesIO(content))
    encoded = base64.b64encode(gzip.compress(archive.getvalue(), compresslevel=9, mtime=0)).decode()
    unpack = "base64 -d | tar -xz"
    if len(encoded) > 23000:
        encoded = base64.b64encode(lzma.compress(archive.getvalue())).decode()
        decoder = "import sys,lzma;sys.stdout.buffer.write(lzma.decompress(sys.stdin.buffer.read()))"
        unpack = "base64 -d | python3 -c " + shlex.quote(decoder) + " | tar -x"
    command = "\n".join([
        "#!/bin/bash", "set -Eeuo pipefail", "umask 077",
        "work_dir=$(mktemp -d)", "trap 'rm -rf \"$work_dir\"' EXIT",
        f"printf '%s' {shlex.quote(encoded)} | {unpack} -C \"$work_dir\"",
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
    parser.add_argument("target", choices=[*SERVER_TARGETS, "dev-agent", "dev-ai-agent", "prod-ai-agent", *AI_TRACING_TARGETS, MARKET_TRACING_TARGET, *METRICS_TARGETS])
    parser.add_argument("--state-json", type=Path, help="Saved terraform output -json; optional for offline rendering")
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--sse-prometheus", action="store_true", help="Enable dev AI scraping; accepted for server compatibility (SSE panels are always included)")
    parser.add_argument("--streamer-metrics-port", type=int, help="Explicit loopback streamer port (contract: 9102); AI agents only")
    args = parser.parse_args()
    if args.streamer_metrics_port is not None and (args.target not in ["dev-ai-agent", "prod-ai-agent"] or not 1024 <= args.streamer_metrics_port <= 65535 or args.streamer_metrics_port in [9101, 12345]):
        parser.error("--streamer-metrics-port requires an AI agent and a non-conflicting port")
    if args.sse_prometheus and args.target not in [*SERVER_TARGETS, "dev-ai-agent"]:
        parser.error("--sse-prometheus requires server or dev-ai-agent")
    if args.target in METRICS_TARGETS:
        settings = market_http_metrics_environment(development=args.target == "dev-ai-metrics")
        content = (json.dumps(settings, indent=2) + "\n" if args.target.startswith("prod")
                   else "".join(f"{key}={value}\n" for key, value in settings.items()))
        args.output.write_text(content)
        args.output.chmod(0o600)
        variable = "MARKET_HTTP_ENV_JSON" if args.target.startswith("prod") else "DEV_AI_ENV"
        print(f"Prepared metrics fragment: {args.output}")
        print(f"Merge into existing {variable}; preserve CloudWatch metrics and other settings.")
        print("Requires the PR #393 image; application rollout is separate.")
        if args.target == "dev-ai-metrics":
            print("EC2 Docker bridge also requires compose.dev-ai-metrics.yaml loopback port mappings.")
        print("No AWS command was submitted. No Terraform apply was executed.")
        return
    if args.state_json:
        outputs = json.loads(args.state_json.read_text())
    else:
        result = subprocess.run(
            ["terraform", f"-chdir={ROOT}", "output", "-json"],
            check=True, text=True, capture_output=True,
        )
        outputs = json.loads(result.stdout)
    if args.target in AI_TRACING_TARGETS:
        args.output.write_text(ai_tracing_environment(args.target, outputs))
        variable = "DEV_AI_ENV" if args.target == "dev-ai-tracing" else "PROD_AI_ENV"
        print(f"Prepared AI tracing fragment: {args.output}")
        print(f"Merge these keys into the existing {variable} GitHub Variable; do not replace its other settings.")
        print("Requires the AI image containing PR #380 and the Tempo network rules. Application rollout is separate.")
    elif args.target == MARKET_TRACING_TARGET:
        args.output.write_text(json.dumps(market_http_tracing_environment(outputs), indent=2) + "\n")
        print(f"Prepared market-http tracing JSON patch: {args.output}")
        print("Merge these keys into the existing MARKET_HTTP_ENV_JSON GitHub Variable; do not replace its other settings.")
        print("Requires the AI image containing PR #380; ECS application rollout is separate.")
    else:
        payload = make_payload(args.target, outputs, sse_prometheus=args.sse_prometheus, streamer_metrics_port=args.streamer_metrics_port)
        args.output.write_text(json.dumps(payload, ensure_ascii=False, indent=2) + "\n")
        print(f"Prepared {args.target} payload for {payload['InstanceIds'][0]}: {args.output}")
        if args.target == "server":
            print("Dashboards are not included; render and send server-dashboards after this payload.")
    args.output.chmod(0o600)
    print("No AWS command was submitted. No Terraform apply was executed.")


if __name__ == "__main__":
    main()
