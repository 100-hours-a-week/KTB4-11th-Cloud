#!/usr/bin/env bash
set -Eeuo pipefail

AWS_REGION="${AWS_REGION:-ap-northeast-2}"
MYSQL_DIRECTORY="/opt/stockspoon-db-private-replica"
MYSQL_CONTAINER="stockspoon-private-db-replica"
ROOT_PASSWORD_FILE="$MYSQL_DIRECTORY/secrets/mysql-root-password"
REPLICATION_PASSWORD_PARAMETER="/stockspoon/v1/db-private-replica/replication-password"
APP_USER_PARAMETER="/stockspoon/v2/prod/backend/MYSQL_USER"
APP_PASSWORD_PARAMETER="/stockspoon/v2/prod/backend/MYSQL_PASSWORD"
MONITOR_PASSWORD_PARAMETER="/stockspoon/v2/prod/backend/PROXYSQL_MONITOR_PASSWORD"
REPLICATION_USER="db_private_replica"
SEED_USER="db_private_seed"
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

cleanup_temporary_files() {
  docker exec "$MYSQL_CONTAINER" rm -f \
    /tmp/private-db-app.cnf \
    /tmp/private-db-monitor.cnf \
    /tmp/private-db-source.cnf \
    /tmp/private-db-target.cnf >/dev/null 2>&1 || true
}
trap cleanup_temporary_files EXIT
wait_for_mysql

sql_escape() {
  printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e "s/'/''/g"
}

replica_status() {
  mysql_root --vertical --execute='SHOW REPLICA STATUS' | sed '/^Empty set /d'
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

verify_mysql_accounts() {
  local app_user app_password monitor_password
  app_user="$(ssm_value "$APP_USER_PARAMETER")"
  app_password="$(ssm_value "$APP_PASSWORD_PARAMETER")"
  monitor_password="$(ssm_value "$MONITOR_PASSWORD_PARAMETER")"
  [[ "$app_user" =~ ^[A-Za-z0-9_]+$ ]] || { echo 'Unexpected backend MySQL username format' >&2; return 1; }

  {
    printf '[client]\nuser=%s\npassword=%s\nhost=127.0.0.1\nport=3306\nprotocol=tcp\n' "$app_user" "$app_password"
  } | docker exec -i "$MYSQL_CONTAINER" sh -c 'umask 077; cat > /tmp/private-db-app.cnf'
  {
    printf '[client]\nuser=%s\npassword=%s\nhost=127.0.0.1\nport=3306\nprotocol=tcp\n' "$MONITOR_USER" "$monitor_password"
  } | docker exec -i "$MYSQL_CONTAINER" sh -c 'umask 077; cat > /tmp/private-db-monitor.cnf'

  docker exec "$MYSQL_CONTAINER" mysql --defaults-extra-file=/tmp/private-db-app.cnf \
    --database=stockspoon --connect-timeout=5 --batch --skip-column-names --execute='SELECT 1' >/dev/null
  docker exec "$MYSQL_CONTAINER" mysql --defaults-extra-file=/tmp/private-db-monitor.cnf \
    --connect-timeout=5 --batch --skip-column-names --execute='SHOW GLOBAL VARIABLES LIKE "read_only"' >/dev/null
  docker exec "$MYSQL_CONTAINER" rm -f /tmp/private-db-app.cnf /tmp/private-db-monitor.cnf
}

ensure_read_only() {
  mysql_root --execute='SET PERSIST read_only=ON; SET PERSIST super_read_only=ON'
}

if [[ "$MODE" == "status" ]]; then
  status_text="$(replica_status)"
  if [[ -z "$status_text" ]]; then
    db_exists="$(mysql_root --batch --skip-column-names --execute="SELECT COUNT(*) FROM information_schema.schemata WHERE schema_name='stockspoon'")"
    if [[ "$db_exists" == "0" ]]; then
      printf '%s\n' 'NEEDS_BOOTSTRAP'
      exit 0
    fi
    echo 'Private MySQL contains stockspoon but has no replication channel; refusing to overwrite it' >&2
    exit 1
  fi

  verify_replica_channel "$status_text"
  [[ "$(status_field "$status_text" Replica_IO_Running)" == 'Yes' \
    && "$(status_field "$status_text" Replica_SQL_Running)" == 'Yes' \
    && "$(status_field "$status_text" Last_IO_Errno)" == '0' \
    && "$(status_field "$status_text" Last_SQL_Errno)" == '0' \
    && "$(status_field "$status_text" Seconds_Behind_Source)" == '0' ]] || {
    echo 'Existing GTID replica is not healthy and caught up; refusing automatic re-seed' >&2
    exit 1
  }
  ensure_read_only
  verify_replica_settings
  verify_mysql_accounts
  printf '%s\n' 'REPLICA_HEALTHY'
  exit 0
fi

# A previous or hand-run partial seed must be inspected by an operator. Never
# delete a database or reset GTIDs as part of a retry.
status_text="$(replica_status)"
if [[ -n "$status_text" ]]; then
  echo 'A replication channel already exists; run status mode and inspect it before retrying' >&2
  exit 1
fi
db_exists="$(mysql_root --batch --skip-column-names --execute="SELECT COUNT(*) FROM information_schema.schemata WHERE schema_name='stockspoon'")"
[[ "$db_exists" == "0" ]] || {
  echo 'Private MySQL already contains stockspoon; refusing to overwrite or reset GTIDs' >&2
  exit 1
}

replication_password="$(ssm_value "$REPLICATION_PASSWORD_PARAMETER")"
app_user="$(ssm_value "$APP_USER_PARAMETER")"
app_password="$(ssm_value "$APP_PASSWORD_PARAMETER")"
monitor_password="$(ssm_value "$MONITOR_PASSWORD_PARAMETER")"
[[ ${#replication_password} -le 32 && ${#replication_password} -ge 16 ]] || {
  echo 'The MySQL replication password must be between 16 and 32 characters' >&2
  exit 1
}
[[ "$app_user" =~ ^[A-Za-z0-9_]+$ ]] || { echo 'Unexpected backend MySQL username format' >&2; exit 1; }
replication_password_sql="$(sql_escape "$replication_password")"
app_password_sql="$(sql_escape "$app_password")"
monitor_password_sql="$(sql_escape "$monitor_password")"

mysql_root --execute='SET GLOBAL super_read_only=OFF; SET GLOBAL read_only=OFF'
mysql_root <<SQL
SET SESSION sql_log_bin=0;
CREATE USER IF NOT EXISTS '$app_user'@'%' IDENTIFIED BY '$app_password_sql';
ALTER USER '$app_user'@'%' IDENTIFIED BY '$app_password_sql';
GRANT ALL PRIVILEGES ON stockspoon.* TO '$app_user'@'%';
CREATE USER IF NOT EXISTS '$MONITOR_USER'@'%' IDENTIFIED BY '$monitor_password_sql';
ALTER USER '$MONITOR_USER'@'%' IDENTIFIED BY '$monitor_password_sql';
GRANT REPLICATION CLIENT ON *.* TO '$MONITOR_USER'@'%';
SQL

{
  printf '[client]\nuser=%s\npassword=%s\nhost=%s\nport=3306\nprotocol=tcp\nssl-mode=REQUIRED\nconnect-timeout=10\n' \
    "$SEED_USER" "$replication_password" "$SOURCE_HOST"
} | docker exec -i "$MYSQL_CONTAINER" sh -c 'umask 077; cat > /tmp/private-db-source.cnf'
{
  printf '[client]\nuser=root\npassword=%s\nhost=127.0.0.1\nport=3306\nprotocol=tcp\n' "$(cat "$ROOT_PASSWORD_FILE")"
} | docker exec -i "$MYSQL_CONTAINER" sh -c 'umask 077; cat > /tmp/private-db-target.cnf'

echo 'Importing a consistent stockspoon snapshot with its source GTID set'
set -o pipefail
docker exec "$MYSQL_CONTAINER" mysqldump \
  --defaults-extra-file=/tmp/private-db-source.cnf \
  --single-transaction \
  --set-gtid-purged=ON \
  --no-tablespaces \
  --routines \
  --events \
  --hex-blob \
  --default-character-set=utf8mb4 \
  --databases stockspoon \
  | docker exec -i "$MYSQL_CONTAINER" mysql --defaults-extra-file=/tmp/private-db-target.cnf

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

ensure_read_only
docker exec "$MYSQL_CONTAINER" rm -f /tmp/private-db-target.cnf

replica_ready=false
for attempt in $(seq 1 90); do
  status_text="$(replica_status)"
  if [[ "$(status_field "$status_text" Source_Host)" == "$SOURCE_HOST" \
    && "$(status_field "$status_text" Source_User)" == "$REPLICATION_USER" \
    && "$(status_field "$status_text" Auto_Position)" == '1' \
    && "$(status_field "$status_text" Source_SSL_Allowed)" == 'Yes' \
    && "$(status_field "$status_text" Replica_IO_Running)" == 'Yes' \
    && "$(status_field "$status_text" Replica_SQL_Running)" == 'Yes' \
    && "$(status_field "$status_text" Last_IO_Errno)" == '0' \
    && "$(status_field "$status_text" Last_SQL_Errno)" == '0' ]]; then
    source_gtid="$(docker exec "$MYSQL_CONTAINER" mysql --defaults-extra-file=/tmp/private-db-source.cnf \
      --batch --skip-column-names --execute='SELECT @@GLOBAL.gtid_executed' 2>/dev/null || true)"
    if [[ -n "$source_gtid" ]]; then
      wait_result="$(mysql_root --batch --skip-column-names \
        --execute="SELECT WAIT_FOR_EXECUTED_GTID_SET('$source_gtid', 20)")"
      if [[ "$wait_result" == '0' \
        && "$(status_field "$(replica_status)" Seconds_Behind_Source)" == '0' ]]; then
        replica_ready=true
        break
      fi
    fi
  fi
  sleep 20
done

[[ "$replica_ready" == true ]] || {
  echo 'Private MySQL did not catch up to the Primary within 30 minutes' >&2
  replica_status >&2
  exit 1
}

verify_mysql_accounts
ensure_read_only
verify_replica_settings
docker exec "$MYSQL_CONTAINER" rm -f /tmp/private-db-source.cnf
mysql_root --batch --skip-column-names --execute='SELECT @@global.read_only, @@global.super_read_only, @@global.gtid_mode'
printf '%s\n' 'REPLICA_BOOTSTRAP_COMPLETE'

