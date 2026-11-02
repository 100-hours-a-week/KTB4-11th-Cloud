#!/usr/bin/env bash
set -Eeuo pipefail

MONITOR_PRIVATE_IP="${1:-10.0.1.85}"
MYSQL_CONTAINER="${2:-stockspoon-private-db-replica}"
AWS_REGION="${AWS_REGION:-ap-northeast-2}"

if ! [[ "$MONITOR_PRIVATE_IP" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
  printf '%s\n' 'MONITOR_PRIVATE_IP must be a private IPv4 address.' >&2
  exit 2
fi

command -v aws >/dev/null
command -v docker >/dev/null

ssm_value() {
  aws ssm get-parameter --region "$AWS_REGION" --name "$1" --with-decryption \
    --query Parameter.Value --output text
}

PMM_PASSWORD="$(ssm_value /stockspoon/v1/db-migration/mysql-monitoring)"
HEARTBEAT_PASSWORD="$(ssm_value /stockspoon/v1/db-migration/mysql-heartbeat)"
for secret in "$PMM_PASSWORD" "$HEARTBEAT_PASSWORD"; do
  if ! [[ "$secret" =~ ^[A-Fa-f0-9]{48}$ ]]; then
    printf '%s\n' 'Monitoring passwords must be the existing 48-character hexadecimal SSM secrets.' >&2
    exit 1
  fi
done

mysql_root() {
  docker exec -i "$MYSQL_CONTAINER" sh -lc \
    'MYSQL_PWD="$(cat /run/secrets/mysql_root_password)" exec mysql --no-defaults --protocol=TCP --host=127.0.0.1 --port=3306 --connect-timeout=5 --user=root "$@"' \
    sh "$@"
}

heartbeat_table_count="$(mysql_root --batch --skip-column-names \
  --execute="SELECT COUNT(*) FROM information_schema.tables WHERE table_schema='stockspoon' AND table_name='monitoring_heartbeat'")"
if [ "$heartbeat_table_count" != 1 ]; then
  printf '%s\n' 'stockspoon.monitoring_heartbeat is missing; wait for replication to catch up before configuring monitoring users.' >&2
  exit 1
fi

# Initial replica baselines copy the application schema, not mysql system users.
# Create monitor accounts locally without adding account-management GTIDs.
restore_read_only() {
  mysql_root --execute='SET PERSIST read_only=ON; SET PERSIST super_read_only=ON' >/dev/null 2>&1 || true
}
trap restore_read_only EXIT
mysql_root --execute='SET GLOBAL super_read_only=OFF; SET GLOBAL read_only=OFF'

mysql_root <<SQL
SET SESSION sql_log_bin=0;
CREATE USER IF NOT EXISTS 'pmm'@'$MONITOR_PRIVATE_IP' IDENTIFIED BY '$PMM_PASSWORD';
ALTER USER 'pmm'@'$MONITOR_PRIVATE_IP' IDENTIFIED BY '$PMM_PASSWORD';
ALTER USER 'pmm'@'$MONITOR_PRIVATE_IP' REQUIRE SSL WITH MAX_USER_CONNECTIONS 10;
GRANT SELECT, PROCESS, REPLICATION CLIENT, RELOAD ON *.* TO 'pmm'@'$MONITOR_PRIVATE_IP';

CREATE USER IF NOT EXISTS 'heartbeat'@'$MONITOR_PRIVATE_IP' IDENTIFIED BY '$HEARTBEAT_PASSWORD';
ALTER USER 'heartbeat'@'$MONITOR_PRIVATE_IP' IDENTIFIED BY '$HEARTBEAT_PASSWORD';
ALTER USER 'heartbeat'@'$MONITOR_PRIVATE_IP' REQUIRE SSL WITH MAX_USER_CONNECTIONS 2;
GRANT SELECT, INSERT, UPDATE, DELETE ON stockspoon.monitoring_heartbeat TO 'heartbeat'@'$MONITOR_PRIVATE_IP';
GRANT REPLICATION CLIENT ON *.* TO 'heartbeat'@'$MONITOR_PRIVATE_IP';
SQL

restore_read_only
trap - EXIT
mysql_root --batch --skip-column-names \
  --execute='SELECT @@GLOBAL.read_only, @@GLOBAL.super_read_only'
printf '%s\n' 'Private replica monitoring accounts configured; read-only mode restored.'
