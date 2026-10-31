#!/usr/bin/env bash
set -Eeuo pipefail

AWS_REGION="${AWS_REGION:-ap-northeast-2}"
MYSQL_CONTAINER="stockspoon-private-db-replica"
ROOT_PASSWORD_FILE="/opt/stockspoon-db-private-replica/secrets/mysql-root-password"
REPLICATION_PASSWORD_PARAMETER="/stockspoon/v1/db-private-replica/replication-password"
MONITOR_PASSWORD_PARAMETER="/stockspoon/v2/prod/backend/PROXYSQL_MONITOR_PASSWORD"
REPLICATION_USER="db_private_replica"
MONITOR_USER="proxysql_monitor"

usage() {
  printf 'Usage: %s status|bootstrap <primary-private-ip>\n' "$0" >&2
  exit 2
}

[[ $# -eq 2 ]] || usage
MODE="$1"
SOURCE_HOST="$2"
[[ "$MODE" == "status" || "$MODE" == "bootstrap" ]] || usage
[[ "$SOURCE_HOST" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || usage
[[ -s "$ROOT_PASSWORD_FILE" ]] || { echo 'MySQL root password file is missing' >&2; exit 1; }

mysql_root() {
  docker exec "$MYSQL_CONTAINER" sh -c \
    'MYSQL_PWD="$(cat /run/secrets/mysql_root_password)" exec mysql --no-defaults --protocol=TCP --host=127.0.0.1 --port=3306 --connect-timeout=5 --user=root "$@"' \
    mysql "$@"
}

wait_for_mysql() {
  for attempt in $(seq 1 90); do
    if mysql_root --batch --skip-column-names --execute='SELECT 1' >/dev/null 2>&1; then
      return 0
    fi
    sleep 10
  done
  echo 'Private MySQL did not become ready within 15 minutes' >&2
  return 1
}

ssm_value() {
  aws ssm get-parameter --region "$AWS_REGION" --name "$1" \
    --with-decryption --query 'Parameter.Value' --output text
}

wait_for_mysql

sql_escape() {
  printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e "s/'/''/g"
}

replica_status() {
  mysql_root --vertical --execute='SHOW REPLICA STATUS' | sed '/^Empty set /d'
}

status_field() {
  local status_text="$1"
  local field_name="$2"
  awk -F': ' -v field_name="$field_name" '
    {
      key = $1
      gsub(/^[[:space:]]+|[[:space:]]+$/, "", key)
      if (key == field_name) {
        print $2
        exit
      }
    }
  ' <<< "$status_text"
}

verify_replica_settings() {
  local replica_flags
  replica_flags="$(mysql_root --batch --skip-column-names --execute='SELECT CONCAT_WS(CHAR(32), @@GLOBAL.gtid_mode, @@GLOBAL.enforce_gtid_consistency, @@GLOBAL.log_bin, @@GLOBAL.read_only, @@GLOBAL.super_read_only)')"
  [[ "$replica_flags" == 'ON ON 1 1 1' ]] || {
    echo "Private MySQL is missing GTID/binlog/read-only protections (flags: $replica_flags)" >&2
    return 1
  }
}

verify_replica_channel() {
  local status_text="$1"
  [[ "$(status_field "$status_text" Source_Host)" == "$SOURCE_HOST" \
    && "$(status_field "$status_text" Source_User)" == "$REPLICATION_USER" \
    && "$(status_field "$status_text" Auto_Position)" == '1' \
    && "$(status_field "$status_text" Source_SSL_Allowed)" == 'Yes' ]] || {
    echo 'Replica channel is not configured for the expected Primary, GTID auto-position, and TLS' >&2
    return 1
  }
}

ensure_read_only() {
  mysql_root --execute='SET PERSIST read_only=ON; SET PERSIST super_read_only=ON'
}

verify_replica_running() {
  local status_text="$1"
  verify_replica_channel "$status_text"
  [[ "$(status_field "$status_text" Replica_IO_Running)" == 'Yes' \
    && "$(status_field "$status_text" Replica_SQL_Running)" == 'Yes' \
    && "$(status_field "$status_text" Last_IO_Errno)" == '0' \
    && "$(status_field "$status_text" Last_SQL_Errno)" == '0' ]] || {
    echo 'GTID replication threads are not running cleanly; inspect SHOW REPLICA STATUS' >&2
    printf '%s\n' "$status_text" >&2
    return 1
  }
}

if [[ "$MODE" == "status" ]]; then
  status_text="$(replica_status)"
  if [[ -z "$status_text" ]]; then
    non_system_schemas="$(mysql_root --batch --skip-column-names --execute="SELECT COUNT(*) FROM information_schema.schemata WHERE schema_name NOT IN ('information_schema','mysql','performance_schema','sys')")"
    [[ "$non_system_schemas" == "0" ]] || {
      echo 'Private MySQL already contains application schemas but has no replication channel; refusing to overwrite it' >&2
      exit 1
    }
    printf '%s\n' 'NEEDS_GTID_CONFIGURATION'
    exit 0
  fi

  verify_replica_running "$status_text"
  ensure_read_only
  verify_replica_settings
  printf '%s\n' 'GTID_REPLICA_THREADS_RUNNING'
  exit 0
fi

status_text="$(replica_status)"
[[ -z "$status_text" ]] || {
  echo 'A replication channel already exists; run status mode and inspect it before retrying' >&2
  exit 1
}

non_system_schemas="$(mysql_root --batch --skip-column-names --execute="SELECT COUNT(*) FROM information_schema.schemata WHERE schema_name NOT IN ('information_schema','mysql','performance_schema','sys')")"
[[ "$non_system_schemas" == "0" ]] || {
  echo 'Private MySQL already contains application schemas; refusing to overwrite or merge them' >&2
  exit 1
}
target_gtid_executed="$(mysql_root --batch --skip-column-names --execute='SELECT @@GLOBAL.gtid_executed')"
[[ -z "$target_gtid_executed" ]] || {
  echo 'Private MySQL already has GTID history; refusing to auto-position an unverified data set' >&2
  exit 1
}

replication_password="$(ssm_value "$REPLICATION_PASSWORD_PARAMETER")"
monitor_password="$(ssm_value "$MONITOR_PASSWORD_PARAMETER")"
[[ "$replication_password" =~ ^[A-Fa-f0-9]{16,32}$ ]] || {
  echo 'The MySQL replication password must be a 16-32 character hexadecimal SSM secret' >&2
  exit 1
}
[[ -n "$monitor_password" ]] || { echo 'ProxySQL monitor password is empty' >&2; exit 1; }
replication_password_sql="$(sql_escape "$replication_password")"
monitor_password_sql="$(sql_escape "$monitor_password")"

# The monitor account is local to this replica because the Primary account is
# intentionally created with sql_log_bin=0. Keep it out of the GTID stream.
mysql_root --execute='SET GLOBAL super_read_only=OFF; SET GLOBAL read_only=OFF'
restore_read_only() {
  mysql_root --execute='SET PERSIST read_only=ON; SET PERSIST super_read_only=ON' >/dev/null
}
trap 'restore_read_only || true' EXIT
mysql_root <<SQL
SET SESSION sql_log_bin=0;
CREATE USER IF NOT EXISTS '$MONITOR_USER'@'%' IDENTIFIED BY '$monitor_password_sql';
ALTER USER '$MONITOR_USER'@'%' IDENTIFIED BY '$monitor_password_sql';
GRANT REPLICATION CLIENT ON *.* TO '$MONITOR_USER'@'%';
SQL
restore_read_only

mysql_root <<SQL
CHANGE REPLICATION SOURCE TO
  SOURCE_HOST='$SOURCE_HOST',
  SOURCE_PORT=3306,
  SOURCE_USER='$REPLICATION_USER',
  SOURCE_PASSWORD='$replication_password_sql',
  SOURCE_AUTO_POSITION=1,
  SOURCE_SSL=1,
  SOURCE_CONNECT_RETRY=10;
START REPLICA;
SQL

replica_ready=false
for attempt in $(seq 1 90); do
  status_text="$(replica_status)"
  if verify_replica_running "$status_text" >/dev/null 2>&1; then
    replica_ready=true
    break
  fi
  sleep 5
done

[[ "$replica_ready" == true ]] || {
  echo 'GTID replication did not establish healthy IO and SQL threads within 7.5 minutes' >&2
  replica_status >&2
  exit 1
}

ensure_read_only
verify_replica_settings
printf '%s\n' 'GTID_REPLICATION_CONFIGURED; source binlogs are applying asynchronously'
