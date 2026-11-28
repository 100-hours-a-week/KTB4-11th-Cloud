#!/usr/bin/env python3
"""Prepare a narrow DB FIS bundle locally, or apply it on the telemetry host."""
import argparse
import base64
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import time
from urllib.request import Request, urlopen

ROOT = Path(__file__).resolve().parents[1]
UID = "stockspoon-db-fis"


def encode(value):
    return (json.dumps(value, ensure_ascii=False, indent=2) + "\n").encode()


def prepare(destination):
    destination.mkdir(parents=True, exist_ok=False)
    shutil.copytree(ROOT / "db-fis", destination / "db-fis", ignore=shutil.ignore_patterns("__pycache__"))
    for name, source in {
        "db-fis.json": ROOT / "config/grafana/dashboards/db-migration/db-fis.json",
        "db-fis.yml": ROOT / "config/prometheus-rules/db-fis.yml",
        "deploy.py": Path(__file__).resolve(),
    }.items():
        shutil.copyfile(source, destination / name)
    hashes = {str(p.relative_to(destination)): hashlib.sha256(p.read_bytes()).hexdigest()
              for p in destination.rglob("*") if p.is_file()}
    (destination / "SHA256.json").write_bytes(encode(hashes))


def run(*args):
    subprocess.run(args, check=True)


def http(url, data=None, headers=None):
    request = Request(url, data=data, headers=headers or {})
    with urlopen(request, timeout=15) as response:
        body = response.read()
    return json.loads(body) if body else None


def apply(bundle, stack):
    for name, expected in json.loads((bundle / "SHA256.json").read_text()).items():
        if hashlib.sha256((bundle / name).read_bytes()).hexdigest() != expected:
            raise ValueError("Bundle checksum mismatch")
    if not (stack / ".env").is_file():
        raise ValueError("Expected existing telemetry stack")
    # Inspect effective config without printing interpolated credentials.
    document = json.loads(subprocess.check_output([
        "docker", "compose", "--project-directory", str(stack), "-f", str(stack / "compose.yaml"),
        "config", "--format", "json"]))
    project = document["name"]
    prom_path = stack / "prometheus.yaml"
    original_prom = prom_path.read_text()
    backup = Path(tempfile.mkdtemp(prefix="stockspoon-db-fis-backup-", dir="/opt"))
    for relative in ["prometheus.yaml", "compose.db-fis.yaml", "prometheus-rules/db-fis.yml",
                     "grafana/dashboards/db-migration/db-fis.json"]:
        source = stack / relative
        if source.exists():
            target = backup / relative
            target.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(source, target)
    # Normalize only the new, independently named scrape job. Preserve live remote-write and other jobs.
    addition = '\n  - job_name: db-fis-observer\n    scrape_interval: 5s\n    static_configs:\n      - targets: ["db-fis-observer:9191"]\n'
    if "job_name: db-fis-observer" not in original_prom and '"job_name": "db-fis-observer"' not in original_prom:
        if not original_prom.lstrip().startswith("global:") or "scrape_configs:" not in original_prom:
            raise ValueError("Unexpected Prometheus format; review the patch before applying")
        prom_path.write_text(original_prom.rstrip() + "\n" + addition)
    targets = {"prometheus-rules/db-fis.yml": "db-fis.yml",
               "grafana/dashboards/db-migration/db-fis.json": "db-fis.json"}
    for relative, source in targets.items():
        path = stack / relative
        path.parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(bundle / source, path)
        path.chmod(0o644)
    shutil.copytree(bundle / "db-fis", stack / "db-fis", dirs_exist_ok=True)
    shutil.copyfile(bundle / "db-fis/compose.yaml", stack / "compose.db-fis.yaml")
    for p in [stack / "grafana/dashboards/db-migration", stack / "prometheus-rules"]:
        p.chmod(0o755)
    data = Path("/srv/stockspoon-telemetry/db-fis")
    data.mkdir(exist_ok=True)
    data.chmod(0o750)
    os.chown(data, 65534, 65534)
    compose = ["docker", "compose", "--project-directory", str(stack), "-p", project,
               "-f", str(stack / "compose.yaml"), "-f", str(stack / "compose.db-fis.yaml")]
    try:
        run(*compose, "config", "--quiet")
        # Validate before reloading; all existing rules must still be valid.
        run(*compose, "exec", "-T", "prometheus", "promtool", "check", "config", "/etc/prometheus/prometheus.yaml")
        # The retained AL2023 server has Compose but no recent buildx plugin.
        subprocess.run(["docker", "build", "-t", "stockspoon-db-fis-observer:local", str(stack / "db-fis")],
                       env={**os.environ, "DOCKER_BUILDKIT": "0"}, check=True)
        run(*compose, "up", "-d", "--no-build", "--no-deps", "db-fis-observer")
        # SIGHUP reloads Prometheus without restarting its storage or other services.
        run(*compose, "kill", "-s", "SIGHUP", "prometheus")
    except Exception:
        prom_path.write_text(original_prom)
        for relative in targets:
            path = stack / relative
            old = backup / relative
            if old.exists():
                shutil.copy2(old, path)
            elif path.exists():
                path.unlink()
        overlay = stack / "compose.db-fis.yaml"
        old_overlay = backup / "compose.db-fis.yaml"
        if old_overlay.exists():
            shutil.copy2(old_overlay, overlay)
        elif overlay.exists():
            overlay.unlink()
        raise
    password = Path("/srv/stockspoon-telemetry/secrets/grafana_admin_password").read_text().strip()
    headers = {"Authorization": "Basic " + base64.b64encode(("admin:" + password).encode()).decode()}
    deadline = time.monotonic() + 55
    while True:
        try:
            dashboard = http("http://127.0.0.1:3000/api/dashboards/uid/" + UID, headers=headers)
            if dashboard["dashboard"]["title"] != "DB FIS · 고객 영향과 자동 복구":
                raise ValueError("Unexpected Grafana dashboard identity")
            break
        except Exception:
            if time.monotonic() >= deadline:
                raise
            time.sleep(2)
    print(json.dumps({"dashboard_uid": UID, "backup": str(backup), "project": project,
                      "observer": "started", "prometheus": "reloaded", "faults_injected": 0}))


def main():
    parser = argparse.ArgumentParser()
    sub = parser.add_subparsers(dest="command", required=True)
    sub.add_parser("prepare").add_argument("destination", type=Path)
    remote = sub.add_parser("apply")
    remote.add_argument("--bundle", type=Path, required=True)
    remote.add_argument("--stack", type=Path, default=Path("/opt/stockspoon-telemetry"))
    args = parser.parse_args()
    if args.command == "prepare":
        prepare(args.destination)
    else:
        apply(args.bundle.resolve(), args.stack.resolve())


if __name__ == "__main__":
    main()
