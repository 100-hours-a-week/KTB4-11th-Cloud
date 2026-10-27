#!/usr/bin/env bash
set -Eeuo pipefail
umask 027

# Run only through a user-submitted SSM payload, after the server payload.
# Grafana re-reads provisioned dashboards every 30s, so no restart is needed.
bundle_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
stack_dir=/opt/stockspoon-telemetry
test -s "$stack_dir/.env"
mountpoint -q /srv/stockspoon-telemetry
mkdir -p "$stack_dir/grafana/dashboards"
backup_dir=$(mktemp -d /opt/stockspoon-telemetry-dashboards-backup.XXXXXX)
cp -a "$stack_dir/grafana/dashboards/." "$backup_dir/"
cp -a "$bundle_dir/config/grafana/dashboards/." "$stack_dir/grafana/dashboards/"
find "$stack_dir/grafana/dashboards" -type d -exec chmod a+rx {} +
find "$stack_dir/grafana/dashboards" -type f -exec chmod a+r {} +
find "$stack_dir/grafana/dashboards" -name '*.json' | sort
printf 'Dashboard backup: %s\n' "$backup_dir"
