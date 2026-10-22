#!/usr/bin/env bash
set -Eeuo pipefail
umask 027

# Run only through a user-submitted SSM payload. Existing .env, EBS data and
# credentials stay in place; installing configs does not replace the server.
bundle_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
stack_dir=/opt/stockspoon-telemetry
test -s "$stack_dir/.env"
mountpoint -q /srv/stockspoon-telemetry
cd "$stack_dir"
backup_dir=$(mktemp -d /opt/stockspoon-telemetry-backup.XXXXXX)
cp -a .env compose.yaml grafana prometheus.yaml loki.yaml tempo.yaml "$backup_dir/"
restart_services=(grafana)
for service in prometheus loki tempo; do
  if ! cmp -s "$bundle_dir/config/$service.yaml" "$stack_dir/$service.yaml"; then
    restart_services+=("$service")
  fi
done
cp -a "$bundle_dir/config/." "$stack_dir/"
install -m 0600 "$bundle_dir/server.env" "$stack_dir/.env"
chmod -R a+rX "$stack_dir/grafana"
chmod a+r "$stack_dir/"*.yaml
docker compose config --quiet
docker compose up -d
# Directory mounts preserve updates, but provisioning changes load on startup.
docker compose restart "${restart_services[@]}"
install -m 0755 "$bundle_dir/smoke.py" "$stack_dir/smoke.py"
docker compose ps
printf 'Configuration backup: %s\n' "$backup_dir"
