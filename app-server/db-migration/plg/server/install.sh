#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
PLG_DIRECTORY="/opt/stockspoon-plg"
AWS_REGION="${AWS_REGION:-ap-northeast-2}"
V1_PRIVATE_IP="${1:-10.0.1.246}"
MIGRATION_DB_PRIVATE_IP="${2:-10.0.1.217}"

is_ipv4() {
  [[ "$1" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]
}

if ! is_ipv4 "$V1_PRIVATE_IP" || ! is_ipv4 "$MIGRATION_DB_PRIVATE_IP"; then
  printf '%s\n' 'Usage: sudo bash install.sh [V1_PRIVATE_IP] [MIGRATION_DB_PRIVATE_IP]' >&2
  exit 2
fi

command -v docker >/dev/null
command -v aws >/dev/null
command -v openssl >/dev/null

install -d -m 0750 "$PLG_DIRECTORY" "$PLG_DIRECTORY/secrets" "$PLG_DIRECTORY/mysqld-exporter" "$PLG_DIRECTORY/heartbeat"
cp -a "$SCRIPT_DIR/." "$PLG_DIRECTORY/"
install -d -m 0750 "$PLG_DIRECTORY/secrets" "$PLG_DIRECTORY/mysqld-exporter" "$PLG_DIRECTORY/heartbeat"

if [ ! -s "$PLG_DIRECTORY/grafana-admin-password" ]; then
  (umask 077; openssl rand -hex 24 > "$PLG_DIRECTORY/grafana-admin-password")
fi
GRAFANA_ADMIN_PASSWORD="$(cat "$PLG_DIRECTORY/grafana-admin-password")"
cat > "$PLG_DIRECTORY/.env" <<EOF
GRAFANA_ADMIN_PASSWORD=$GRAFANA_ADMIN_PASSWORD
V1_PRIVATE_IP=$V1_PRIVATE_IP
MIGRATION_DB_PRIVATE_IP=$MIGRATION_DB_PRIVATE_IP
EOF
chmod 0600 "$PLG_DIRECTORY/.env" "$PLG_DIRECTORY/grafana-admin-password"

MYSQL_EXPORTER_PASSWORD="$(aws ssm get-parameter --region "$AWS_REGION" \
  --name /stockspoon/v1/db-migration/mysql-monitoring --with-decryption \
  --query Parameter.Value --output text)"
if [ -z "$MYSQL_EXPORTER_PASSWORD" ] || [ "$MYSQL_EXPORTER_PASSWORD" = "None" ]; then
  printf '%s\n' 'Could not read the existing MySQL monitoring password from SSM Parameter Store.' >&2
  exit 1
fi
cat > "$PLG_DIRECTORY/mysqld-exporter/.my.cnf" <<EOF
[client]
user = pmm
password = $MYSQL_EXPORTER_PASSWORD
EOF
unset MYSQL_EXPORTER_PASSWORD
chmod 0600 "$PLG_DIRECTORY/mysqld-exporter/.my.cnf"
chown root:65534 "$PLG_DIRECTORY/mysqld-exporter/.my.cnf"
chmod 0440 "$PLG_DIRECTORY/mysqld-exporter/.my.cnf"

# The heartbeat MySQL accounts are created on the primary with this password
# (OPERATIONS.md 8-7). A new password here requires ALTER USER on the primary.
if [ ! -s "$PLG_DIRECTORY/secrets/mysql-heartbeat-password" ]; then
  (umask 077; openssl rand -hex 24 > "$PLG_DIRECTORY/secrets/mysql-heartbeat-password")
fi
(umask 077; printf '[client]\nuser = heartbeat\npassword = %s\n' \
  "$(cat "$PLG_DIRECTORY/secrets/mysql-heartbeat-password")" > "$PLG_DIRECTORY/heartbeat/.my.cnf")
chown root:root "$PLG_DIRECTORY/heartbeat/.my.cnf"
# pt-heartbeat runs as uid 1001 with gid 0.
chmod 0440 "$PLG_DIRECTORY/heartbeat/.my.cnf"

install -d -m 0750 "$PLG_DIRECTORY/alertmanager/secrets"
DISCORD_WEBHOOK_URL="$(aws ssm get-parameter --region "$AWS_REGION" \
  --name /stockspoon/v1/db-migration/discord-webhook --with-decryption \
  --query Parameter.Value --output text)"
if [[ "$DISCORD_WEBHOOK_URL" != https://discord.com/api/webhooks/* ]]; then
  printf '%s\n' 'Could not read a Discord webhook URL from SSM Parameter Store.' >&2
  exit 1
fi
(umask 077; printf '%s' "$DISCORD_WEBHOOK_URL" > "$PLG_DIRECTORY/alertmanager/secrets/discord-webhook")
unset DISCORD_WEBHOOK_URL
# Alertmanager runs as nobody (65534).
chown root:65534 "$PLG_DIRECTORY/alertmanager/secrets" "$PLG_DIRECTORY/alertmanager/secrets/discord-webhook"
chmod 0440 "$PLG_DIRECTORY/alertmanager/secrets/discord-webhook"

sed \
  -e "s/__V1_PRIVATE_IP__/$V1_PRIVATE_IP/g" \
  -e "s/__MIGRATION_DB_PRIVATE_IP__/$MIGRATION_DB_PRIVATE_IP/g" \
  "$SCRIPT_DIR/prometheus.yml.tmpl" > "$PLG_DIRECTORY/prometheus.yml"

cd "$PLG_DIRECTORY"
COMPOSE=(docker compose --env-file .env -f compose.yaml)
if [ -s https/public.env ]; then
  COMPOSE=(docker compose --env-file .env --env-file https/public.env -f compose.yaml -f compose.https.yaml)
fi
"${COMPOSE[@]}" config --quiet

PMM_WAS_RUNNING=false
if docker container inspect migration-pmm-server >/dev/null 2>&1 \
  && [ "$(docker inspect -f '{{.State.Running}}' migration-pmm-server)" = true ]; then
  PMM_WAS_RUNNING=true
  docker stop migration-pmm-server >/dev/null
fi

if ! "${COMPOSE[@]}" up -d; then
  if [ "$PMM_WAS_RUNNING" = true ]; then docker start migration-pmm-server >/dev/null; fi
  exit 1
fi

ready=false
for attempt in $(seq 1 60); do
  if curl --fail --silent http://127.0.0.1:3100/ready >/dev/null \
    && curl --fail --silent http://127.0.0.1:9090/-/ready >/dev/null \
    && curl --fail --silent http://127.0.0.1:9093/-/ready >/dev/null \
    && curl --fail --silent http://127.0.0.1:3000/api/health >/dev/null; then
    ready=true
    break
  fi
  sleep 5
done
if [ "$ready" != true ]; then
  "${COMPOSE[@]}" down
  if [ "$PMM_WAS_RUNNING" = true ]; then docker start migration-pmm-server >/dev/null; fi
  printf '%s\n' 'PLG readiness check failed; PMM was restored if it was running before installation.' >&2
  exit 1
fi

printf 'PLG is ready. Grafana admin password: %s/grafana-admin-password\n' "$PLG_DIRECTORY"
printf 'Prometheus targets use V1=%s and migration DB=%s.\n' "$V1_PRIVATE_IP" "$MIGRATION_DB_PRIVATE_IP"
