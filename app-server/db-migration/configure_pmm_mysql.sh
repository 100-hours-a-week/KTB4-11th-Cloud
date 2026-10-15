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
aws ssm get-parameter --region "$AWS_REGION" \
  --name /stockspoon/v1/db-migration/mysql-monitoring --with-decryption \
  --query Parameter.Value --output text > "$PMM_DIRECTORY/mysql-monitor-password"

if ! docker exec migration-pmm-server pmm-admin list | grep -q 'migration-target'; then
  docker exec migration-pmm-server pmm-admin add mysql \
    --host="$MYSQL_PRIVATE_IP" --port=3306 --username=pmm \
    --password="$(cat "$PMM_DIRECTORY/mysql-monitor-password")" \
    --query-source=perfschema --environment=rehearsal \
    --tls --tls-skip-verify --metrics-mode=push migration-target
fi

docker exec migration-pmm-server pmm-admin list
docker exec migration-pmm-server pmm-admin status
