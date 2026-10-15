#!/usr/bin/env bash
set -Eeuo pipefail

MYSQL_PRIVATE_IP="$1"
AWS_REGION="${AWS_REGION:-ap-northeast-2}"
PMM_DIRECTORY="/opt/stockspoon-pmm"

if ! [[ "$MYSQL_PRIVATE_IP" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  printf '%s\n' 'Expected the migration MySQL private IPv4 address' >&2
  exit 1
fi

umask 077
if [ ! -s "$PMM_DIRECTORY/admin-password" ]; then
  printf '%s\n' 'PMM administrator password file is missing' >&2
  exit 1
fi

PMM_SERVER_URL="https://admin:$(cat "$PMM_DIRECTORY/admin-password")@127.0.0.1:8443"
pmm_admin() {
  docker exec migration-pmm-server pmm-admin \
    --server-url="$PMM_SERVER_URL" --server-insecure-tls "$@"
}

# Fail on authentication errors before checking whether the service exists.
PMM_SERVICES="$(pmm_admin list)"
aws ssm get-parameter --region "$AWS_REGION" \
  --name /stockspoon/v1/db-migration/mysql-monitoring --with-decryption \
  --query Parameter.Value --output text > "$PMM_DIRECTORY/mysql-monitor-password"

if ! grep -q 'migration-target' <<< "$PMM_SERVICES"; then
  # Exporters on PMM Server's built-in agent must use pull metrics mode.
  pmm_admin add mysql \
    --host="$MYSQL_PRIVATE_IP" --port=3306 --username=pmm \
    --password="$(cat "$PMM_DIRECTORY/mysql-monitor-password")" \
    --query-source=perfschema --environment=rehearsal \
    --tls --tls-skip-verify --metrics-mode=pull migration-target
fi

pmm_admin list
pmm_admin status
