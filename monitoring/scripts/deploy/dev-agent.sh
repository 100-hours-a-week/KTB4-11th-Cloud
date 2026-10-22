#!/usr/bin/env bash
set -Eeuo pipefail
umask 027

bundle_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
agent_dir=/opt/stockspoon-telemetry-agent
docker info >/dev/null
docker compose version >/dev/null
install -d -m 0755 "$agent_dir"
install -d -m 0750 /var/lib/stockspoon-v2-dev-alloy
install -m 0644 "$bundle_dir/dev-agent/compose.yaml" "$agent_dir/compose.yaml"
install -m 0644 "$bundle_dir/dev-agent/config.alloy" "$agent_dir/config.alloy"
install -m 0644 "$bundle_dir/agent.env" "$agent_dir/.env"
printf 'TELEMETRY_HOST=%s\n' "$(hostname)" >> "$agent_dir/.env"
for service in backend frontend; do
  install -m 0644 "$bundle_dir/$service.otel.env" "$agent_dir/$service.otel.env"
done
cd "$agent_dir"
docker compose config --quiet
docker compose run --rm --no-deps alloy validate /etc/alloy/config.alloy
docker compose up -d
# Alloy reads its config on startup; the bind-mounted file is updated above.
docker compose restart alloy
docker compose ps
