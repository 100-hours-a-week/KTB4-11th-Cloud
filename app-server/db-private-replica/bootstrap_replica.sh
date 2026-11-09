#!/usr/bin/env bash
set -Eeuo pipefail

AWS_REGION="${AWS_REGION:-ap-northeast-2}"
MYSQL_CONTAINER="stockspoon-private-db-replica"
ROOT_PASSWORD_FILE="/opt/stockspoon-db-private-replica/secrets/mysql-root-password"
SEED_MARKER="/opt/stockspoon-db-private-replica/seed-complete"
SEED_ATTEMPT_MARKER="/opt/stockspoon-db-private-replica/seed-started"
SEED_DUMP_COMPLETE_MARKER="/opt/stockspoon-db-private-replica/seed-dump-complete"
SEED_OPTION_FILE=""
REPLICATION_PASSWORD_PARAMETER="/stockspoon/v1/db-private-replica/replication-password"
MONITOR_PASSWORD_PARAMETER="/stockspoon/v2/prod/backend/PROXYSQL_MONITOR_PASSWORD"
APP_USER_PARAMETER="/stockspoon/v2/prod/backend/MYSQL_USER"
APP_PASSWORD_PARAMETER="/stockspoon/v2/prod/backend/MYSQL_PASSWORD"
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
  # Keep stdin attached so SQL supplied through a heredoc reaches mysql.
  docker exec -i "$MYSQL_CONTAINER" sh -c \
    'MYSQL_PWD="$(cat /run/secrets/mysql_root_password)" exec mysql --no-defaults --protocol=SOCKET --socket=/var/run/mysqld/mysqld.sock --connect-timeout=5 --user=root "$@"' \
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
  mysql_root --batch --skip-column-names \
    --execute="SELECT REPLACE(REPLACE(@@GLOBAL.gtid_executed, CHAR(10), ''), CHAR(13), '')"
}

target_gtid_purged() {
  mysql_root --batch --skip-column-names \
    --execute="SELECT REPLACE(REPLACE(@@GLOBAL.gtid_purged, CHAR(10), ''), CHAR(13), '')"
}

expected_marker_contents() {
  printf '%s\n%s' "$SOURCE_INSTANCE_ID" "$SOURCE_HOST"
}

verify_incomplete_seed_attempt_source() {
  local marker_source marker_host marker_format
  [[ -s "$SEED_ATTEMPT_MARKER" ]] || {
    echo 'The incomplete baseline marker is missing or empty; refusing automatic retry' >&2
    return 1
  }
  marker_source="$(sed -n '1p' "$SEED_ATTEMPT_MARKER")"
  marker_host="$(sed -n '2p' "$SEED_ATTEMPT_MARKER")"
  marker_format="$(sed -n '3p' "$SEED_ATTEMPT_MARKER")"
  [[ "$marker_source" == "$SOURCE_INSTANCE_ID" && "$marker_host" == "$SOURCE_HOST" ]] || {
    echo 'The incomplete baseline attempt belongs to a different Primary; refusing automatic retry' >&2
    return 1
  }
  [[ -z "$marker_format" || "$marker_format" == 'format=2' ]] || {
    echo 'The incomplete baseline marker has an unsupported format; refusing automatic recovery' >&2
    return 1
  }
}

application_object_manifest() {
  mysql_root --batch --skip-column-names --execute="
    SELECT CONCAT('TABLE:', table_name, ':', table_type)
    FROM information_schema.tables
    WHERE table_schema='stockspoon'
    UNION ALL
    SELECT CONCAT('ROUTINE:', routine_name, ':', routine_type)
    FROM information_schema.routines
    WHERE routine_schema='stockspoon'
    UNION ALL
    SELECT CONCAT('EVENT:', event_name)
    FROM information_schema.events
    WHERE event_schema='stockspoon'
    UNION ALL
    SELECT CONCAT('TRIGGER:', trigger_name, ':', event_object_table, ':', action_timing, ':', event_manipulation)
    FROM information_schema.triggers
    WHERE trigger_schema='stockspoon'
    ORDER BY 1"
}

source_application_object_manifest() {
  docker exec "$MYSQL_CONTAINER" mysql \
    --defaults-extra-file="$SEED_OPTION_FILE" \
    --protocol=TCP --host="$SOURCE_HOST" --port=3306 --connect-timeout=10 \
    --ssl-mode=REQUIRED --batch --skip-column-names \
    --execute="
      SELECT CONCAT('TABLE:', table_name, ':', table_type)
      FROM information_schema.tables
      WHERE table_schema='stockspoon'
      UNION ALL
      SELECT CONCAT('ROUTINE:', routine_name, ':', routine_type)
      FROM information_schema.routines
      WHERE routine_schema='stockspoon'
      UNION ALL
      SELECT CONCAT('EVENT:', event_name)
      FROM information_schema.events
      WHERE event_schema='stockspoon'
      UNION ALL
      SELECT CONCAT('TRIGGER:', trigger_name, ':', event_object_table, ':', action_timing, ':', event_manipulation)
      FROM information_schema.triggers
      WHERE trigger_schema='stockspoon'
      ORDER BY 1"
}

incomplete_seed_attempt_status() {
  local channel_status schemas executed purged marker_format dump_marker_contents
  verify_incomplete_seed_attempt_source || return 1
  channel_status="$(replica_status)" || return 1
  [[ -z "$channel_status" ]] || {
    echo 'A replication channel exists after an incomplete baseline attempt; refusing automatic recovery' >&2
    return 1
  }
  schemas="$(application_schemas)" || return 1
  executed="$(target_gtid_executed)" || return 1
  if [[ -z "$schemas" && -z "$executed" ]]; then
    printf '%s\n' 'BASELINE_ATTEMPT_SAFE_TO_RETRY'
    return 0
  fi
  [[ "$schemas" == 'stockspoon' && -n "$executed" ]] || {
    echo 'Incomplete baseline has an unexpected schema or GTID state; manual inspection is required' >&2
    return 1
  }
  marker_format="$(sed -n '3p' "$SEED_ATTEMPT_MARKER")"
  if [[ -s "$SEED_DUMP_COMPLETE_MARKER" ]]; then
    dump_marker_contents="$(cat "$SEED_DUMP_COMPLETE_MARKER")"
    [[ "$dump_marker_contents" == "$(expected_marker_contents)" ]] || {
      echo 'The completed dump marker belongs to a different Primary; refusing automatic recovery' >&2
      return 1
    }
  elif [[ -z "$marker_format" ]]; then
    # Legacy attempts have no dump-complete marker. Allow verification only
    # when the imported GTID_PURGED exactly matches the replica's GTID history.
    purged="$(target_gtid_purged)" || return 1
    [[ -n "$purged" && "$purged" == "$executed" ]] || {
      echo 'Legacy incomplete baseline has no complete GTID snapshot; manual inspection is required' >&2
      return 1
    }
  else
    echo 'The baseline dump was not recorded as complete; refusing automatic recovery' >&2
    return 1
  fi
  printf '%s\n' 'BASELINE_ATTEMPT_NEEDS_GTID_VALIDATION'
}

verify_incomplete_seed_baseline() {
  local channel_status schemas executed purged source_manifest target_manifest
  verify_incomplete_seed_attempt_source || return 1
  channel_status="$(replica_status)" || return 1
  [[ -z "$channel_status" ]] || {
    echo 'A replication channel exists after an incomplete baseline attempt; refusing adoption' >&2
    return 1
  }
  schemas="$(application_schemas)" || return 1
  [[ "$schemas" == 'stockspoon' ]] || {
    echo 'Incomplete baseline does not contain exactly the stockspoon schema; refusing adoption' >&2
    return 1
  }
  executed="$(target_gtid_executed)" || return 1
  purged="$(target_gtid_purged)" || return 1
  [[ -n "$executed" && "$purged" == "$executed" ]] || {
    echo 'Incomplete baseline does not have a complete imported GTID snapshot; refusing adoption' >&2
    return 1
  }
  source_manifest="$(source_application_object_manifest)" || return 1
  target_manifest="$(application_object_manifest)" || return 1
  [[ -n "$source_manifest" && "$source_manifest" == "$target_manifest" ]] || {
    echo 'Primary and Replica schema objects do not match; refusing baseline adoption' >&2
    return 1
  }
  verify_seed_gtid_history || return 1
  ensure_read_only || return 1
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

verify_existing_replica_data() {
  [[ "$(application_schemas)" == 'stockspoon' ]] || {
    echo 'Existing Private MySQL replica does not contain exactly the stockspoon application schema' >&2
    return 1
  }
  [[ -n "$(target_gtid_executed)" ]] || {
    echo 'Existing Private MySQL replica has no GTID history; refusing to adopt its replication channel' >&2
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
    --execute="SELECT REPLACE(REPLACE(@@GLOBAL.gtid_executed, CHAR(10), ''), CHAR(13), ''), REPLACE(REPLACE(@@GLOBAL.gtid_purged, CHAR(10), ''), CHAR(13), '')")"
  [[ "$gtid_output" == *$'\t'* ]] || {
    echo 'Could not read both GTID sets from the Primary' >&2
    return 1
  }
  SOURCE_GTID_EXECUTED="${gtid_output%%$'\t'*}"
  SOURCE_GTID_PURGED="${gtid_output#*$'\t'}"
  [[ -n "$SOURCE_GTID_EXECUTED" ]] || {
    echo 'The Primary has an empty gtid_executed set; refusing baseline replication' >&2
    return 1
  }
}

verify_seed_gtid_history() {
  local source_executed_sql source_purged_sql target_executed target_executed_sql checks
  source_gtid_sets || return 1
  source_executed_sql="$(sql_escape "$SOURCE_GTID_EXECUTED")"
  source_purged_sql="$(sql_escape "$SOURCE_GTID_PURGED")"
  target_executed="$(target_gtid_executed)" || return 1
  [[ -n "$target_executed" ]] || {
    echo 'Private MySQL has no GTID history after baseline import' >&2
    return 1
  }
  target_executed_sql="$(sql_escape "$target_executed")"
  checks="$(mysql_root --batch --skip-column-names --execute="SELECT GTID_SUBSET('$source_purged_sql', '$target_executed_sql'), GTID_SUBSET('$target_executed_sql', '$source_executed_sql')")" || return 1
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
    rm -f "$SEED_DUMP_COMPLETE_MARKER"
    printf '%s\n' 'BASELINE_ALREADY_SEEDED_AND_GTID_HISTORY_VALID'
    return 0
  fi

  if [[ -e "$SEED_ATTEMPT_MARKER" ]]; then
    local attempt_status
    attempt_status="$(incomplete_seed_attempt_status)" || return 1
    if [[ "$attempt_status" == 'BASELINE_ATTEMPT_NEEDS_GTID_VALIDATION' ]]; then
      verify_incomplete_seed_baseline || return 1
      marker_tmp="${SEED_MARKER}.tmp.$$"
      expected_marker_contents > "$marker_tmp"
      chmod 0600 "$marker_tmp"
      mv "$marker_tmp" "$SEED_MARKER"
      rm -f "$SEED_ATTEMPT_MARKER" "$SEED_DUMP_COMPLETE_MARKER"
      printf '%s\n' 'BASELINE_RECOVERED_WITHOUT_REIMPORT'
      return 0
    fi
    echo 'Previous baseline attempt left an empty target; retrying the seed safely' >&2
  fi

  schemas="$(application_schemas)"
  [[ -z "$schemas" ]] || {
    echo 'Private MySQL already contains application schemas without a completed baseline marker; refusing to overwrite or merge it' >&2
    return 1
  }
  current_gtids="$(target_gtid_executed)"
  printf '%s\n%s\nformat=2\n' "$SOURCE_INSTANCE_ID" "$SOURCE_HOST" > "$SEED_ATTEMPT_MARKER"
  chmod 0600 "$SEED_ATTEMPT_MARKER"
  rm -f "$SEED_DUMP_COMPLETE_MARKER"
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
    --protocol=TCP --host="$SOURCE_HOST" --port=3306 \
    --ssl-mode=REQUIRED --single-transaction --quick --set-gtid-purged=ON \
    --databases stockspoon --routines --events --triggers --hex-blob --no-tablespaces \
    | docker exec -i "$MYSQL_CONTAINER" sh -c \
      'MYSQL_PWD="$(cat /run/secrets/mysql_root_password)" exec mysql --no-defaults --protocol=SOCKET --socket=/var/run/mysqld/mysqld.sock --connect-timeout=5 --user=root'
  ensure_read_only

  [[ "$(application_schemas)" == 'stockspoon' ]] || {
    echo 'Baseline import did not produce exactly the stockspoon application schema' >&2
    return 1
  }
  marker_tmp="${SEED_DUMP_COMPLETE_MARKER}.tmp.$$"
  expected_marker_contents > "$marker_tmp"
  chmod 0600 "$marker_tmp"
  mv "$marker_tmp" "$SEED_DUMP_COMPLETE_MARKER"
  verify_seed_gtid_history

  marker_tmp="${SEED_MARKER}.tmp.$$"
  expected_marker_contents > "$marker_tmp"
  chmod 0600 "$marker_tmp"
  mv "$marker_tmp" "$SEED_MARKER"
  rm -f "$SEED_ATTEMPT_MARKER" "$SEED_DUMP_COMPLETE_MARKER"
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
    if [[ -e "$SEED_ATTEMPT_MARKER" ]]; then
      incomplete_seed_attempt_status
      exit 0
    fi
    non_system_schemas="$(application_schemas)"
    [[ -z "$non_system_schemas" ]] || {
      echo 'Private MySQL has unmarked application data; refusing to overwrite or merge it' >&2
      exit 1
    }
    printf '%s\n' 'NEEDS_BASELINE_SEED'
    exit 0
  fi

  verify_existing_replica_data
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
app_user="$(ssm_value "$APP_USER_PARAMETER")"
app_password="$(ssm_value "$APP_PASSWORD_PARAMETER")"
[[ "$replication_password" =~ ^[A-Fa-f0-9]{16,32}$ ]] || {
  echo 'The MySQL replication password must be a 16-32 character hexadecimal SSM secret' >&2
  exit 1
}
[[ -n "$monitor_password" ]] || { echo 'ProxySQL monitor password is empty' >&2; exit 1; }
[[ "$app_user" =~ ^[A-Za-z0-9_]{1,32}$ ]] || { echo 'Backend MySQL username is invalid' >&2; exit 1; }
[[ -n "$app_password" ]] || { echo 'Backend MySQL password is empty' >&2; exit 1; }
replication_password_sql="$(sql_escape "$replication_password")"
monitor_password_sql="$(sql_escape "$monitor_password")"
app_user_sql="$(sql_escape "$app_user")"
app_password_sql="$(sql_escape "$app_password")"

heartbeat_table_count="$(mysql_root --batch --skip-column-names \
  --execute="SELECT COUNT(*) FROM information_schema.tables WHERE table_schema='stockspoon' AND table_name='monitoring_heartbeat'")"
[[ "$heartbeat_table_count" == '1' ]] || {
  echo 'stockspoon.monitoring_heartbeat is missing from the seeded baseline' >&2
  exit 1
}

# The dump contains app tables but not mysql.user. Recreate the existing app
# and monitoring accounts locally without adding account GTIDs to the stream.
mysql_root --execute='SET GLOBAL super_read_only=OFF; SET GLOBAL read_only=OFF'
trap 'restore_read_only || true' EXIT
mysql_root <<SQL
SET SESSION sql_log_bin=0;
CREATE USER IF NOT EXISTS '$app_user_sql'@'%' IDENTIFIED BY '$app_password_sql';
ALTER USER '$app_user_sql'@'%' IDENTIFIED BY '$app_password_sql';
GRANT ALL PRIVILEGES ON stockspoon.* TO '$app_user_sql'@'%';

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
