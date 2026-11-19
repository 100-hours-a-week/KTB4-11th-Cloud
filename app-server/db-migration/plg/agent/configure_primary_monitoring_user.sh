#!/usr/bin/env bash
set -Eeuo pipefail

MONITOR_PRIVATE_IP="${1:-}"
MYSQL_CONTAINER="${2:-migration-mysql-seed-20261019}"
AWS_REGION="${AWS_REGION:-ap-northeast-2}"

if ! [[ "$MONITOR_PRIVATE_IP" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
  printf '%s\n' 'MONITOR_PRIVATE_IP must be an IPv4 address.' >&2
  exit 2
fi

command -v aws >/dev/null
command -v docker >/dev/null
docker inspect "$MYSQL_CONTAINER" >/dev/null

ssm_value() {
  aws ssm get-parameter --region "$AWS_REGION" --name "$1" --with-decryption \
    --query Parameter.Value --output text
}

PMM_PASSWORD="$(ssm_value /stockspoon/v1/db-migration/mysql-monitoring)"
HEARTBEAT_PASSWORD="$(ssm_value /stockspoon/v1/db-migration/mysql-heartbeat)"
for secret in "$PMM_PASSWORD" "$HEARTBEAT_PASSWORD"; do
  if ! [[ "$secret" =~ ^[A-Fa-f0-9]{48}$ ]]; then
    printf '%s\n' 'Monitoring passwords do not match the expected SSM secret format.' >&2
    exit 1
  fi
done

mysql_root() {
  docker exec -i "$MYSQL_CONTAINER" sh -lc \
    'MYSQL_PWD="$(cat /run/secrets/mysql_root_password)" exec mysql --no-defaults --protocol=SOCKET --socket=/var/run/mysqld/mysqld.sock --connect-timeout=5 --user=root "$@"' \
    sh "$@"
}

read_only_state="$(mysql_root --batch --skip-column-names \
  --execute='SELECT CONCAT(@@GLOBAL.read_only, ",", @@GLOBAL.super_read_only)')"
if [ "$read_only_state" != "0,0" ]; then
  printf 'The active Primary is not writable (read_only,super_read_only=%s); no account changes made.\n' \
    "$read_only_state" >&2
  exit 1
fi

heartbeat_table_count="$(mysql_root --batch --skip-column-names \
  --execute="SELECT COUNT(*) FROM information_schema.tables WHERE table_schema='stockspoon' AND table_name='monitoring_heartbeat'")"
if [ "$heartbeat_table_count" != 1 ]; then
  printf '%s\n' 'stockspoon.monitoring_heartbeat is missing; no account changes made.' >&2
  exit 1
fi

# Keep account metadata local to this Primary instead of adding GTIDs to replication.
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

unset PMM_PASSWORD HEARTBEAT_PASSWORD secret
read_only_state="$(mysql_root --batch --skip-column-names \
  --execute='SELECT CONCAT(@@GLOBAL.read_only, ",", @@GLOBAL.super_read_only)')"
if [ "$read_only_state" != "0,0" ]; then
  printf 'The Primary write state changed unexpectedly (read_only,super_read_only=%s).\n' \
    "$read_only_state" >&2
  exit 1
fi
printf '%s\n' 'Primary monitoring accounts configured; writable mode remains unchanged.'
