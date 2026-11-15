#!/usr/bin/env bash
set -Eeuo pipefail

usage() {
  cat >&2 <<'USAGE'
Usage:
  configure_semisync.sh source-prepare
  configure_semisync.sh replica-enable
  configure_semisync.sh source-enable

Run on the corresponding MySQL EC2 host through SSM Run Command.
MYSQL_CONTAINER can override the current container name.
USAGE
  exit 2
}

[[ $# -eq 1 ]] || usage
ACTION="$1"

case "$ACTION" in
  source-prepare)
    ROLE="source"
    MYSQL_CONTAINER="${MYSQL_CONTAINER:-migration-mysql-seed-20261019}"
    PLUGIN="rpl_semi_sync_source"
    PLUGIN_LIBRARY="semisync_source.so"
    EXPECTED_SERVER_ID="104"
    ;;
  replica-enable)
    ROLE="replica"
    MYSQL_CONTAINER="${MYSQL_CONTAINER:-stockspoon-private-db-replica}"
    PLUGIN="rpl_semi_sync_replica"
    PLUGIN_LIBRARY="semisync_replica.so"
    EXPECTED_SERVER_ID="105"
    ;;
  source-enable)
    ROLE="source"
    MYSQL_CONTAINER="${MYSQL_CONTAINER:-migration-mysql-seed-20261019}"
    PLUGIN="rpl_semi_sync_source"
    PLUGIN_LIBRARY="semisync_source.so"
    EXPECTED_SERVER_ID="104"
    ;;
  *) usage ;;
esac

mysql_root() {
  docker exec -i "$MYSQL_CONTAINER" sh -c \
    'export MYSQL_PWD="$(cat /run/secrets/mysql_root_password)"; exec mysql --no-defaults --protocol=TCP --host=127.0.0.1 --user=root --connect-timeout=5 --batch --skip-column-names --raw "$@"' \
    sh "$@"
}

[[ "$(docker inspect --format '{{.State.Running}}' "$MYSQL_CONTAINER")" == "true" ]] || {
  echo "MySQL container is not running: $MYSQL_CONTAINER" >&2
  exit 1
}

server_id="$(mysql_root --execute='SELECT @@server_id')"
read_only="$(mysql_root --execute='SELECT @@global.read_only')"
super_read_only="$(mysql_root --execute='SELECT @@global.super_read_only')"
gtid_mode="$(mysql_root --execute='SELECT @@global.gtid_mode')"
log_bin="$(mysql_root --execute='SELECT @@global.log_bin')"
plugin_dir="$(mysql_root --execute='SELECT @@plugin_dir')"

[[ "$server_id" == "$EXPECTED_SERVER_ID" ]] || {
  echo "Refusing unexpected MySQL server_id=$server_id for $ROLE (expected $EXPECTED_SERVER_ID)" >&2
  exit 1
}
[[ "$gtid_mode" == "ON" && "$log_bin" == "1" ]] || {
  echo "GTID or binary logging is disabled; refusing Semi-sync setup" >&2
  exit 1
}
if [[ "$ROLE" == "source" ]]; then
  [[ "$read_only" == "0" && "$super_read_only" == "0" ]] || {
    echo "Expected writable source; read_only=$read_only super_read_only=$super_read_only" >&2
    exit 1
  }
else
  [[ "$read_only" == "1" && "$super_read_only" == "1" ]] || {
    echo "Expected protected replica; read_only=$read_only super_read_only=$super_read_only" >&2
    exit 1
  }
fi

plugin_file="${plugin_dir%/}/$PLUGIN_LIBRARY"
docker exec "$MYSQL_CONTAINER" test -r "$plugin_file" || {
  echo "Semi-sync plugin library not found: $plugin_file" >&2
  exit 1
}

plugin_status="$(mysql_root --execute="SELECT COALESCE(MAX(PLUGIN_STATUS), '') FROM INFORMATION_SCHEMA.PLUGINS WHERE PLUGIN_NAME = '$PLUGIN'")"
restore_super_read_only=0
restore_read_only_guard() {
  if [[ "$restore_super_read_only" == "1" ]]; then
    mysql_root --execute='SET GLOBAL super_read_only = ON' >/dev/null
    restore_super_read_only=0
  fi
}
trap restore_read_only_guard EXIT

if [[ -z "$plugin_status" ]]; then
  if [[ "$ROLE" == "replica" ]]; then
    # INSTALL PLUGIN is blocked by super_read_only. Keep read_only=ON while
    # briefly lowering only the stronger guard, and always restore it on exit.
    mysql_root --execute='SET GLOBAL super_read_only = OFF'
    restore_super_read_only=1
  fi
  mysql_root --execute="INSTALL PLUGIN $PLUGIN SONAME '$PLUGIN_LIBRARY'"
  plugin_status="$(mysql_root --execute="SELECT PLUGIN_STATUS FROM INFORMATION_SCHEMA.PLUGINS WHERE PLUGIN_NAME = '$PLUGIN'")"
fi
[[ "$plugin_status" == "ACTIVE" ]] || {
  echo "Semi-sync plugin is not ACTIVE: $PLUGIN ($plugin_status)" >&2
  exit 1
}

case "$ACTION" in
  source-prepare)
    mysql_root --execute="SET PERSIST rpl_semi_sync_source_timeout = 10000;
      SET PERSIST rpl_semi_sync_source_wait_for_replica_count = 1;
      SET PERSIST rpl_semi_sync_source_wait_point = 'AFTER_SYNC'"
    echo "Prepared source Semi-sync plugin and persistent settings; source remains disabled."
    ;;
  replica-enable)
    receiver="$(mysql_root --execute="SELECT COALESCE(MAX(SERVICE_STATE), '') FROM performance_schema.replication_connection_status WHERE CHANNEL_NAME = ''")"
    applier="$(mysql_root --execute="SELECT COALESCE(MAX(SERVICE_STATE), '') FROM performance_schema.replication_applier_status WHERE CHANNEL_NAME = ''")"
    [[ "$receiver" == "ON" && "$applier" == "ON" ]] || {
      echo "Replication channel must be healthy before enabling Semi-sync (receiver=$receiver applier=$applier)" >&2
      exit 1
    }
    previous_enabled="$(mysql_root --execute='SELECT @@global.rpl_semi_sync_replica_enabled')"
    mysql_root --execute='SET PERSIST rpl_semi_sync_replica_enabled = ON'
    if [[ "$previous_enabled" != "1" ]]; then
      mysql_root --execute='STOP REPLICA IO_THREAD; START REPLICA IO_THREAD'
    fi
    restore_read_only_guard
    echo "Enabled replica Semi-sync and refreshed the replication receiver."
    ;;
  source-enable)
    mysql_root --execute='SET PERSIST rpl_semi_sync_source_enabled = ON'
    echo "Enabled source Semi-sync with a 10-second ACK timeout and one replica ACK."
    ;;
esac

echo "MySQL role=$ROLE server_id=$server_id plugin=$PLUGIN status=$plugin_status"
