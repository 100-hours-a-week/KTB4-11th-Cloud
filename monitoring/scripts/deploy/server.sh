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
for path in prometheus-rules alertmanager; do
  if [ -e "$path" ]; then
    cp -a "$path" "$backup_dir/"
  fi
done
restart_services=(grafana prometheus alertmanager heartbeat-primary heartbeat-private-replica)
for service in loki tempo; do
  if ! cmp -s "$bundle_dir/config/$service.yaml" "$stack_dir/$service.yaml"; then
    restart_services+=("$service")
  fi
done
cp -a "$bundle_dir/config/." "$stack_dir/"
install -m 0600 "$bundle_dir/server.env" "$stack_dir/.env"
install -d -m 0750 /srv/stockspoon-telemetry/secrets/db-migration
install -d -o 65534 -g 65534 -m 0750 /srv/stockspoon-telemetry/alertmanager
monitoring_password=$(aws ssm get-parameter \
  --region ap-northeast-2 \
  --name /stockspoon/v1/db-migration/mysql-monitoring \
  --with-decryption --query Parameter.Value --output text)
heartbeat_password=$(aws ssm get-parameter \
  --region ap-northeast-2 \
  --name /stockspoon/v1/db-migration/mysql-heartbeat \
  --with-decryption --query Parameter.Value --output text)
discord_webhook=$(aws ssm get-parameter \
  --region ap-northeast-2 \
  --name /stockspoon/v1/db-migration/discord-webhook \
  --with-decryption --query Parameter.Value --output text)
for secret in "$monitoring_password" "$heartbeat_password"; do
  if ! [[ "$secret" =~ ^[A-Fa-f0-9]{48}$ ]]; then
    printf '%s\n' 'DB monitoring passwords do not match the expected SSM secret format.' >&2
    exit 1
  fi
done
if ! [[ "$discord_webhook" =~ ^https://(discord\.com|discordapp\.com)/api/webhooks/[0-9]+/[A-Za-z0-9_.-]+$ ]]; then
  printf '%s\n' 'The DB monitoring Discord webhook has an unexpected format.' >&2
  exit 1
fi
for node in primary private-replica; do
  printf '[client]\nuser=pmm\npassword=%s\n' "$monitoring_password" \
    > "/srv/stockspoon-telemetry/secrets/db-migration/mysql-${node}.cnf"
  chown root:65534 "/srv/stockspoon-telemetry/secrets/db-migration/mysql-${node}.cnf"
  chmod 0440 "/srv/stockspoon-telemetry/secrets/db-migration/mysql-${node}.cnf"
done
printf '[client]\nuser = heartbeat\npassword = %s\n' "$heartbeat_password" \
  > /srv/stockspoon-telemetry/secrets/db-migration/heartbeat.cnf
chown root:0 /srv/stockspoon-telemetry/secrets/db-migration/heartbeat.cnf
chmod 0440 /srv/stockspoon-telemetry/secrets/db-migration/heartbeat.cnf
printf '%s\n' "$discord_webhook" > /srv/stockspoon-telemetry/secrets/discord-webhook
chown root:65534 /srv/stockspoon-telemetry/secrets/discord-webhook
chmod 0440 /srv/stockspoon-telemetry/secrets/discord-webhook
unset monitoring_password heartbeat_password discord_webhook secret
find "$stack_dir/grafana" -type d -exec chmod a+rx {} +
find "$stack_dir/grafana" -type f ! -name '*.local.json' -exec chmod a+r {} +
find "$stack_dir/prometheus-rules" -type d -exec chmod a+rx {} +
find "$stack_dir/prometheus-rules" -type f -exec chmod a+r {} +
find "$stack_dir/alertmanager" -type d -exec chmod a+rx {} +
find "$stack_dir/alertmanager" -type f -exec chmod a+r {} +
chmod a+r "$stack_dir/"*.yaml
install -m 0755 "$bundle_dir/configure-alerting.py" "$stack_dir/configure-alerting.py"
python3 "$stack_dir/configure-alerting.py" --sync-aws
docker compose config --quiet
docker compose up -d
# Directory mounts preserve updates, but provisioning changes load on startup.
docker compose restart "${restart_services[@]}"
install -m 0755 "$bundle_dir/smoke.py" "$stack_dir/smoke.py"
docker compose ps
printf 'Configuration backup: %s\n' "$backup_dir"
