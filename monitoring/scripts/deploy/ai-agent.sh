#!/usr/bin/env bash
set -Eeuo pipefail
umask 027

bundle_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
agent_dir=/opt/stockspoon-ai-telemetry-agent
docker info >/dev/null
docker compose version >/dev/null
install -d -m 0755 "$agent_dir"
install -d -m 0750 /var/lib/stockspoon-ai-alloy
install -m 0644 "$bundle_dir/ai-agent/compose.yaml" "$agent_dir/compose.yaml"
install -m 0644 "$bundle_dir/ai-agent/config.alloy" "$agent_dir/config.alloy"
install -m 0644 "$bundle_dir/agent.env" "$agent_dir/.env"
printf 'TELEMETRY_HOST=%s\n' "$(hostname)" >> "$agent_dir/.env"
cd "$agent_dir"
docker compose --project-name stockspoon-ai-telemetry config --quiet
docker compose --project-name stockspoon-ai-telemetry run --rm --no-deps alloy validate /etc/alloy/config.alloy
docker compose --project-name stockspoon-ai-telemetry up -d
# Alloy reads its config on startup; the bind-mounted file is updated above.
docker compose --project-name stockspoon-ai-telemetry restart alloy
docker compose --project-name stockspoon-ai-telemetry ps
