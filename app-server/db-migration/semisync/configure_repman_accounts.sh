#!/usr/bin/env bash
set -Eeuo pipefail

usage() {
  echo "Usage: $0 source|replica" >&2
  exit 2
}

[[ $# -eq 1 ]] || usage
ROLE="$1"
AWS_REGION="${AWS_REGION:-ap-northeast-2}"
DB_PASSWORD_PARAMETER="/stockspoon/v2/prod/repman/MYSQL_PASSWORD"
REPLICATION_PASSWORD_PARAMETER="/stockspoon/v1/db-private-replica/replication-password"

case "$ROLE" in
  source)
    MYSQL_CONTAINER="${MYSQL_CONTAINER:-migration-mysql-seed-20261019}"
    EXPECTED_SERVER_ID="104"
    ;;
  replica)
    MYSQL_CONTAINER="${MYSQL_CONTAINER:-stockspoon-private-db-replica}"
    EXPECTED_SERVER_ID="105"
    ;;
  *) usage ;;
esac

mysql_root() {
  docker exec -i "$MYSQL_CONTAINER" sh -c \
    'export MYSQL_PWD="$(cat /run/secrets/mysql_root_password)"; exec mysql --no-defaults --protocol=TCP --host=127.0.0.1 --user=root --connect-timeout=5 --batch --skip-column-names --raw "$@"' \
    sh "$@"
}

ssm_value() {
  aws ssm get-parameter --region "$AWS_REGION" --name "$1" \
    --with-decryption --query 'Parameter.Value' --output text
}

server_id="$(mysql_root --execute='SELECT @@server_id')"
read_only="$(mysql_root --execute='SELECT @@global.read_only')"
super_read_only="$(mysql_root --execute='SELECT @@global.super_read_only')"
gtid_mode="$(mysql_root --execute='SELECT @@global.gtid_mode')"
[[ "$server_id" == "$EXPECTED_SERVER_ID" && "$gtid_mode" == "ON" ]] || {
  echo "Refusing unexpected MySQL identity or GTID state (server_id=$server_id, gtid_mode=$gtid_mode)" >&2
  exit 1
}

db_password="$(ssm_value "$DB_PASSWORD_PARAMETER")"
replication_password="$(ssm_value "$REPLICATION_PASSWORD_PARAMETER")"
[[ "$db_password" =~ ^[A-Fa-f0-9]{32,64}$ ]] || {
  echo 'Repman database password must be a 32-64 character hexadecimal SSM SecureString' >&2
  exit 1
}
[[ "$replication_password" =~ ^[A-Fa-f0-9]{16,32}$ ]] || {
  echo 'Replication password must be a 16-32 character hexadecimal SSM SecureString' >&2
  exit 1
}

restore_super_read_only=0
restore_read_only_guard() {
  if [[ "$restore_super_read_only" == "1" ]]; then
    mysql_root --execute='SET GLOBAL super_read_only=ON' >/dev/null
    restore_super_read_only=0
  fi
}
trap restore_read_only_guard EXIT

if [[ "$ROLE" == "source" ]]; then
  [[ "$read_only" == "0" && "$super_read_only" == "0" ]] || {
    echo 'Expected a writable source before setting up Repman accounts' >&2
    exit 1
  }
  # Keep Repman metadata in the MySQL binlog so it follows the promoted node.
  mysql_root --execute='CREATE DATABASE IF NOT EXISTS replication_manager_schema'
else
  [[ "$read_only" == "1" && "$super_read_only" == "1" ]] || {
    echo 'Expected a protected read-only replica before setting up Repman accounts' >&2
    exit 1
  }
  for attempt in $(seq 1 60); do
    [[ "$(mysql_root --execute="SELECT COUNT(*) FROM information_schema.schemata WHERE schema_name='replication_manager_schema'")" == "1" ]] && break
    [[ "$attempt" -lt 60 ]] || {
      echo 'Repman metadata schema did not replicate from the Primary within five minutes' >&2
      exit 1
    }
    sleep 5
  done
  # The account DDL is local to each node. Keep read_only=ON while briefly
  # lowering only super_read_only for privileged account and grant statements.
  mysql_root --execute='SET GLOBAL super_read_only=OFF'
  restore_super_read_only=1
fi

mysql_root <<SQL
SET SESSION sql_log_bin=0;
CREATE USER IF NOT EXISTS 'repman'@'%' IDENTIFIED BY '$db_password' PASSWORD EXPIRE NEVER;
ALTER USER 'repman'@'%' IDENTIFIED BY '$db_password' PASSWORD EXPIRE NEVER;
GRANT SELECT, PROCESS, REPLICATION CLIENT, REPLICATION SLAVE, RELOAD ON *.* TO 'repman'@'%';
GRANT REPLICATION_SLAVE_ADMIN, BINLOG_ADMIN, SYSTEM_VARIABLES_ADMIN, CONNECTION_ADMIN ON *.* TO 'repman'@'%';
# Replication Manager v3.1.x still checks mysql.user.Super_priv on MySQL 8,
# even though the dynamic equivalents are granted above. Keep this compatibility
# grant until its privilege checker recognizes those dynamic privileges.
GRANT SUPER ON *.* TO 'repman'@'%';
GRANT ALL PRIVILEGES ON replication_manager_schema.* TO 'repman'@'%';

CREATE USER IF NOT EXISTS 'repman_repl'@'%' IDENTIFIED BY '$replication_password' PASSWORD EXPIRE NEVER;
ALTER USER 'repman_repl'@'%' IDENTIFIED BY '$replication_password' PASSWORD EXPIRE NEVER;
GRANT REPLICATION SLAVE ON *.* TO 'repman_repl'@'%';
SQL

restore_read_only_guard

final_flags="$(mysql_root --execute='SELECT CONCAT(@@global.read_only, CHAR(32), @@global.super_read_only)')"
if [[ "$ROLE" == "replica" && "$final_flags" != '1 1' ]]; then
  echo "Replica write protection did not return to ON (flags=$final_flags)" >&2
  exit 1
fi

echo "Repman monitoring and replication accounts are ready on role=$ROLE server_id=$server_id"
