#!/usr/bin/env bash
set -Eeuo pipefail

AWS_REGION="${AWS_REGION:-ap-northeast-2}"
MYSQL_CONTAINER="stockspoon-private-db-replica"
ROOT_PASSWORD_FILE="/opt/stockspoon-db-private-replica/secrets/mysql-root-password"
SEED_MARKER="/opt/stockspoon-db-private-replica/seed-complete"
SEED_ATTEMPT_MARKER="/opt/stockspoon-db-private-replica/seed-started"
SEED_OPTION_FILE=""
REPLICATION_PASSWORD_PARAMETER="/stockspoon/v1/db-private-replica/replication-password"
MONITOR_PASSWORD_PARAMETER="/stockspoon/v2/prod/backend/PROXYSQL_MONITOR_PASSWORD"
REPLICATION_USER="db_private_replica"
SEED_USER="db_private_seed"
MONITOR_USER="proxysql_monitor"

usage() {
  printf 'Usage: %s status|seed|bootstrap <primary-private-ip> <primary-instance-id>\n' "$0" >&2
  exit 2
}

[[ $# -eq 3 ]] || usage
MODE="$1"
SOURCE_HOST="$2"
SOURCE_INSTANCE_ID="$3"
[[ "$MODE" == "status" || "$MODE" == "seed" || "$MODE" == "bootstrap" ]] || usage
[[ "$SOURCE_HOST" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || usage
[[ "$SOURCE_INSTANCE_ID" =~ ^i-[0-9a-f]+$ ]] || usage
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

application_schemas() {
  mysql_root --batch --skip-column-names --execute="SELECT COALESCE(GROUP_CONCAT(schema_name ORDER BY schema_name SEPARATOR ','), '') FROM information_schema.schemata WHERE schema_name NOT IN ('information_schema','mysql','performance_schema','sys')"
}

target_gtid_executed() {
  mysql_root --batch --skip-column-names --execute='SELECT @@GLOBAL.gtid_executed'
}

expected_marker_contents() {
  printf '%s\n%s' "$SOURCE_INSTANCE_ID" "$SOURCE_HOST"
}

verify_seed_marker() {
  [[ -s "$SEED_MARKER" ]] || {
    echo 'Private MySQL has no completed baseline marker; refusing replication setup' >&2
    return 1
  }
  [[ "$(cat "$SEED_MARKER")" == "$(expected_marker_contents)" ]] || {
    echo 'Private MySQL baseline belongs to a different Primary instance; refusing replication setup' >&2
    return 1
  }
}

verify_seeded_data() {
  verify_seed_marker
  [[ "$(application_schemas)" == 'stockspoon' ]] || {
    echo 'Private MySQL baseline does not contain exactly the stockspoon application schema' >&2
    return 1
  }
  [[ -n "$(target_gtid_executed)" ]] || {
    echo 'Private MySQL baseline has no GTID history; refusing replication setup' >&2
    return 1
  }
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

restore_read_only() {
  mysql_root --execute='SET PERSIST read_only=ON; SET PERSIST super_read_only=ON' >/dev/null
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

install_seed_client_config() {
  local seed_password
  seed_password="$(ssm_value "$REPLICATION_PASSWORD_PARAMETER")"
  [[ "$seed_password" =~ ^[A-Fa-f0-9]{16,32}$ ]] || {
    echo 'The MySQL seed password must be a 16-32 character hexadecimal SSM secret' >&2
    return 1
  }
  SEED_OPTION_FILE="$(docker exec "$MYSQL_CONTAINER" sh -c 'umask 077; mktemp /tmp/stockspoon-private-db-seed.XXXXXX')"
  printf '[client]\nuser=%s\npassword=%s\nssl-mode=REQUIRED\n' "$SEED_USER" "$seed_password" \
    | docker exec -i "$MYSQL_CONTAINER" sh -c 'cat > "$1"' sh "$SEED_OPTION_FILE"
}

remove_seed_client_config() {
  [[ -z "$SEED_OPTION_FILE" ]] || docker exec "$MYSQL_CONTAINER" rm -f "$SEED_OPTION_FILE" >/dev/null 2>&1 || true
}

source_gtid_sets() {
  local gtid_output
  gtid_output="$(docker exec "$MYSQL_CONTAINER" mysql \
    --defaults-extra-file="$SEED_OPTION_FILE" \
    --protocol=TCP --host="$SOURCE_HOST" --port=3306 --connect-timeout=10 \
    --ssl-mode=REQUIRED --batch --skip-column-names \
    --execute='SELECT CONCAT("EXECUTED:", @@GLOBAL.gtid_executed); SELECT CONCAT("PURGED:", @@GLOBAL.gtid_purged)')"
  [[ "$gtid_output" == *$'\n'* ]] || {
    echo 'Could not read both GTID sets from the Primary' >&2
    return 1
  }
  SOURCE_GTID_EXECUTED="${gtid_output%%$'\n'*}"
  SOURCE_GTID_PURGED="${gtid_output#*$'\n'}"
  SOURCE_GTID_EXECUTED="${SOURCE_GTID_EXECUTED#EXECUTED:}"
  SOURCE_GTID_PURGED="${SOURCE_GTID_PURGED#PURGED:}"
  [[ -n "$SOURCE_GTID_EXECUTED" ]] || {
    echo 'The Primary has an empty gtid_executed set; refusing baseline replication' >&2
    return 1
  }
}

verify_seed_gtid_history() {
  local source_executed_sql source_purged_sql target_executed target_executed_sql checks
  source_gtid_sets
  source_executed_sql="$(sql_escape "$SOURCE_GTID_EXECUTED")"
  source_purged_sql="$(sql_escape "$SOURCE_GTID_PURGED")"
  target_executed="$(target_gtid_executed)"
  [[ -n "$target_executed" ]] || {
    echo 'Private MySQL has no GTID history after baseline import' >&2
    return 1
  }
  target_executed_sql="$(sql_escape "$target_executed")"
  checks="$(mysql_root --batch --skip-column-names --execute="SELECT GTID_SUBSET('$source_purged_sql', '$target_executed_sql'), GTID_SUBSET('$target_executed_sql', '$source_executed_sql')")"
  [[ "$checks" == $'1\t1' ]] || {
    echo 'Baseline GTID history is not safe for auto-position; the Primary may have purged transactions since the snapshot' >&2
    return 1
  }
}

seed_baseline() {
  local status_text schemas current_gtids marker_tmp
  status_text="$(replica_status)"
  [[ -z "$status_text" ]] || {
    echo 'A replication channel already exists; refusing to seed a running replica' >&2
    return 1
  }

  trap 'restore_read_only >/dev/null 2>&1 || true; remove_seed_client_config' EXIT
  install_seed_client_config

  if [[ -s "$SEED_MARKER" ]]; then
    verify_seeded_data
    verify_seed_gtid_history
    rm -f "$SEED_ATTEMPT_MARKER"
    printf '%s\n' 'BASELINE_ALREADY_SEEDED_AND_GTID_HISTORY_VALID'
    return 0
  fi

  [[ ! -e "$SEED_ATTEMPT_MARKER" ]] || {
    echo 'A previous baseline attempt did not finish; refusing to reset or overwrite the target' >&2
    return 1
  }

  schemas="$(application_schemas)"
  [[ -z "$schemas" ]] || {
    echo 'Private MySQL already contains application schemas without a completed baseline marker; refusing to overwrite or merge it' >&2
    return 1
  }
  current_gtids="$(target_gtid_executed)"
  printf '%s\n%s\n' "$SOURCE_INSTANCE_ID" "$SOURCE_HOST" > "$SEED_ATTEMPT_MARKER"
  chmod 0600 "$SEED_ATTEMPT_MARKER"
  if [[ -n "$current_gtids" ]]; then
    # A brand-new MySQL Docker data directory can have local initialization
    # transactions. It is empty and has no channel, so clear only this replica's
    # local binlogs/GTID state before importing the source baseline.
    mysql_root --execute='RESET BINARY LOGS AND GTIDS'
  fi
  [[ -z "$(target_gtid_executed)" ]] || {
    echo 'Could not clear initialization GTID history on the empty private replica' >&2
    return 1
  }

  mysql_root --execute='SET GLOBAL super_read_only=OFF; SET GLOBAL read_only=OFF'
  docker exec "$MYSQL_CONTAINER" mysqldump \
    --defaults-extra-file="$SEED_OPTION_FILE" \
    --protocol=TCP --host="$SOURCE_HOST" --port=3306 --connect-timeout=10 \
    --ssl-mode=REQUIRED --single-transaction --quick --set-gtid-purged=ON \
    --databases stockspoon --routines --events --triggers --hex-blob --no-tablespaces \
    | docker exec -i "$MYSQL_CONTAINER" sh -c \
      'MYSQL_PWD="$(cat /run/secrets/mysql_root_password)" exec mysql --no-defaults --protocol=TCP --host=127.0.0.1 --port=3306 --connect-timeout=5 --user=root'
  ensure_read_only

  [[ "$(application_schemas)" == 'stockspoon' ]] || {
    echo 'Baseline import did not produce exactly the stockspoon application schema' >&2
    return 1
  }
  verify_seed_gtid_history

  marker_tmp="${SEED_MARKER}.tmp.$$"
  expected_marker_contents > "$marker_tmp"
  chmod 0600 "$marker_tmp"
  mv "$marker_tmp" "$SEED_MARKER"
  rm -f "$SEED_ATTEMPT_MARKER"
  printf '%s\n' 'BASELINE_SEEDED_AND_GTID_HISTORY_VALID'
}

if [[ "$MODE" == "status" ]]; then
  status_text="$(replica_status)"
  if [[ -z "$status_text" ]]; then
    if [[ -s "$SEED_MARKER" ]]; then
      verify_seeded_data
      printf '%s\n' 'BASELINE_SEEDED_NEEDS_GTID_CONFIGURATION'
      exit 0
    fi
    [[ ! -e "$SEED_ATTEMPT_MARKER" ]] || {
      echo 'A previous baseline attempt did not finish; refusing to reset or overwrite the target' >&2
      exit 1
    }
    non_system_schemas="$(application_schemas)"
    [[ -z "$non_system_schemas" ]] || {
      echo 'Private MySQL has unmarked application data; refusing to overwrite or merge it' >&2
      exit 1
    }
    printf '%s\n' 'NEEDS_BASELINE_SEED'
    exit 0
  fi

  verify_seeded_data
  verify_replica_running "$status_text"
  ensure_read_only
  verify_replica_settings
  printf '%s\n' 'GTID_REPLICA_THREADS_RUNNING'
  exit 0
fi

if [[ "$MODE" == "seed" ]]; then
  seed_baseline
  exit 0
fi

status_text="$(replica_status)"
[[ -z "$status_text" ]] || {
  echo 'A replication channel already exists; run status mode and inspect it before retrying' >&2
  exit 1
}

verify_seeded_data

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
