#!/usr/bin/env python3
"""Configure GTID auto-position replication over SSM without taking a seed."""

from __future__ import annotations

import base64
import gzip
import json
import os
import subprocess
import tempfile
import time
from ipaddress import IPv4Address
from pathlib import Path

REGION = os.environ.get("AWS_REGION", "ap-northeast-2")
COMMAND_TIMEOUT_SECONDS = 900
POLL_SECONDS = 10

SOURCE_PREFLIGHT = r"""#!/usr/bin/env bash
set -Eeuo pipefail
MYSQL_CONTAINER=migration-mysql
mysql_root() {
  docker exec "$MYSQL_CONTAINER" sh -c \
    'MYSQL_PWD="$(cat /run/secrets/mysql_root_password)" exec mysql --no-defaults --protocol=TCP --host=127.0.0.1 --port=3306 --connect-timeout=5 --user=root "$@"' \
    mysql "$@"
}
source_flags="$(mysql_root --batch --skip-column-names --execute='SELECT CONCAT_WS(CHAR(32), @@GLOBAL.read_only, @@GLOBAL.super_read_only, @@GLOBAL.gtid_mode, @@GLOBAL.enforce_gtid_consistency, @@GLOBAL.log_bin, @@GLOBAL.binlog_format)' | tr '\t' ' ')"
[[ "$source_flags" == '0 0 ON ON 1 ROW' ]] || {
  echo "The configured Primary is not writable with GTID/binlog enabled (flags: $source_flags); refusing replica configuration" >&2
  exit 1
}
purged_gtids="$(mysql_root --batch --skip-column-names --execute='SELECT @@GLOBAL.gtid_purged' | tr -d '\r\n')"
[[ -z "$purged_gtids" ]] || {
  echo 'SEED_REQUIRED: the Primary has purged GTID history. An empty replica cannot recover those existing rows from GTID replication alone.' >&2
  echo 'Restore a baseline or retain the complete source binlog history before starting an empty replica.' >&2
  exit 42
}
echo 'PRIMARY_READY_FOR_SEEDLESS_GTID_REPLICATION'
"""

SOURCE_PREPARE = r"""#!/usr/bin/env bash
set -Eeuo pipefail
AWS_REGION=ap-northeast-2
TARGET_HOST=@@TARGET_IP@@
PARAMETER=/stockspoon/v1/db-private-replica/replication-password
MYSQL_CONTAINER=migration-mysql
ROOT_PASSWORD_FILE=/opt/stockspoon-db-migration/mysql/secrets/mysql-root-password
[[ "$TARGET_HOST" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]
[[ -s "$ROOT_PASSWORD_FILE" ]]
replication_password=''
for attempt in $(seq 1 12); do
  if replication_password="$(aws ssm get-parameter --region "$AWS_REGION" --name "$PARAMETER" --with-decryption --query 'Parameter.Value' --output text 2>/dev/null)"; then
    break
  fi
  [[ "$attempt" -lt 12 ]] || { echo 'Unable to retrieve the replication password from Parameter Store' >&2; exit 1; }
  sleep 5
done
[[ "$replication_password" =~ ^[A-Fa-f0-9]{16,32}$ ]] || {
  echo 'Replication password must be a 16-32 character hexadecimal SSM secret' >&2
  exit 1
}
docker exec "$MYSQL_CONTAINER" sh -c \
  'MYSQL_PWD="$(cat /run/secrets/mysql_root_password)" exec mysql --no-defaults --protocol=TCP --host=127.0.0.1 --port=3306 --connect-timeout=5 --user=root' <<SQL
SET SESSION sql_log_bin=0;
CREATE USER IF NOT EXISTS 'db_private_replica'@'$TARGET_HOST' IDENTIFIED BY '$replication_password' REQUIRE SSL;
ALTER USER 'db_private_replica'@'$TARGET_HOST' IDENTIFIED BY '$replication_password' REQUIRE SSL;
GRANT REPLICATION SLAVE ON *.* TO 'db_private_replica'@'$TARGET_HOST';
SQL
echo 'SOURCE_REPLICATION_ACCOUNT_READY'
"""

SOURCE_MONITOR_PREPARE = r"""#!/usr/bin/env bash
set -Eeuo pipefail
AWS_REGION=ap-northeast-2
PARAMETER=/stockspoon/v2/prod/backend/PROXYSQL_MONITOR_PASSWORD
MYSQL_CONTAINER=migration-mysql
ROOT_PASSWORD_FILE=/opt/stockspoon-db-migration/mysql/secrets/mysql-root-password
[[ -s "$ROOT_PASSWORD_FILE" ]]
monitor_password=''
for attempt in $(seq 1 12); do
  if monitor_password="$(aws ssm get-parameter --region "$AWS_REGION" --name "$PARAMETER" --with-decryption --query 'Parameter.Value' --output text 2>/dev/null)"; then
    break
  fi
  [[ "$attempt" -lt 12 ]] || { echo 'Unable to retrieve the ProxySQL monitor password from Parameter Store' >&2; exit 1; }
  sleep 5
done
monitor_password_sql="$(printf '%s' "$monitor_password" | sed -e 's/\\/\\\\/g' -e "s/'/''/g")"
docker exec "$MYSQL_CONTAINER" sh -c \
  'MYSQL_PWD="$(cat /run/secrets/mysql_root_password)" exec mysql --no-defaults --protocol=TCP --host=127.0.0.1 --port=3306 --connect-timeout=5 --user=root' <<SQL
SET SESSION sql_log_bin=0;
CREATE USER IF NOT EXISTS 'proxysql_monitor'@'%' IDENTIFIED BY '$monitor_password_sql';
ALTER USER 'proxysql_monitor'@'%' IDENTIFIED BY '$monitor_password_sql';
GRANT REPLICATION CLIENT ON *.* TO 'proxysql_monitor'@'%';
SQL
echo 'PRIMARY_PROXYSQL_MONITOR_READY'
"""

SOURCE_DROP_LEGACY_SEED = r"""#!/usr/bin/env bash
set -Eeuo pipefail
TARGET_HOST=@@TARGET_IP@@
MYSQL_CONTAINER=migration-mysql
ROOT_PASSWORD_FILE=/opt/stockspoon-db-migration/mysql/secrets/mysql-root-password
[[ "$TARGET_HOST" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]
[[ -s "$ROOT_PASSWORD_FILE" ]]
docker exec "$MYSQL_CONTAINER" sh -c \
  'MYSQL_PWD="$(cat /run/secrets/mysql_root_password)" exec mysql --no-defaults --protocol=TCP --host=127.0.0.1 --port=3306 --connect-timeout=5 --user=root' <<SQL
SET SESSION sql_log_bin=0;
DROP USER IF EXISTS 'db_private_seed'@'$TARGET_HOST';
SQL
echo 'LEGACY_SEED_ACCOUNT_REMOVED'
"""


def run_aws_json(arguments: list[str]) -> dict:
    for attempt in range(12):
        try:
            result = subprocess.run(
                ["aws", *arguments, "--region", REGION, "--output", "json"],
                check=True,
                text=True,
                capture_output=True,
            )
            return json.loads(result.stdout)
        except subprocess.CalledProcessError as error:
            details = f"{error.stderr}\n{error.stdout}"
            if attempt == 11 or not any(
                token in details
                for token in ("AccessDenied", "not authorized", "UnauthorizedOperation")
            ):
                raise
            time.sleep(5)
    raise RuntimeError("AWS CLI retry loop ended unexpectedly")


def instance_environment() -> tuple[str, str, str, str]:
    source_id = os.environ["DB_PRIMARY_INSTANCE_ID"]
    source_ip = os.environ["DB_PRIMARY_PRIVATE_IP"]
    target_id = os.environ["DB_PRIVATE_REPLICA_INSTANCE_ID"]
    target_ip = os.environ["DB_PRIVATE_REPLICA_PRIVATE_IP"]
    IPv4Address(source_ip)
    IPv4Address(target_ip)
    if source_id == target_id:
        raise RuntimeError("Primary and private replica resolve to the same EC2 instance")
    return source_id, source_ip, target_id, target_ip


def wait_for_ssm(instance_id: str) -> None:
    deadline = time.monotonic() + 1800
    while time.monotonic() < deadline:
        response = run_aws_json(
            [
                "ssm",
                "describe-instance-information",
                "--filters",
                f"Key=InstanceIds,Values={instance_id}",
            ]
        )
        instances = response.get("InstanceInformationList", [])
        if instances and instances[0].get("PingStatus") == "Online":
            return
        time.sleep(15)
    raise TimeoutError(f"EC2 instance {instance_id} did not become SSM Online within 30 minutes")


def run_ssm(instance_id: str, script: str, label: str, timeout: int = COMMAND_TIMEOUT_SECONDS) -> str:
    request = {
        "DocumentName": "AWS-RunShellScript",
        "InstanceIds": [instance_id],
        "TimeoutSeconds": timeout,
        "Parameters": {"commands": [script]},
        "Comment": f"StockSpoon private DB replica: {label}",
    }
    with tempfile.NamedTemporaryFile(mode="w", suffix=".json", encoding="utf-8") as request_file:
        json.dump(request, request_file)
        request_file.flush()
        response = run_aws_json(["ssm", "send-command", "--cli-input-json", f"file://{request_file.name}"])
    command_id = response["Command"]["CommandId"]
    print(f"SSM command started for {label} (id {command_id})", flush=True)

    deadline = time.monotonic() + timeout + 120
    last_progress = 0
    while time.monotonic() < deadline:
        try:
            invocation = run_aws_json(
                [
                    "ssm",
                    "get-command-invocation",
                    "--command-id",
                    command_id,
                    "--instance-id",
                    instance_id,
                ]
            )
        except subprocess.CalledProcessError:
            time.sleep(POLL_SECONDS)
            continue

        status = invocation.get("Status", "Unknown")
        terminal = {
            "Success", "Cancelled", "TimedOut", "Failed", "Cancelling",
            "DeliveryTimedOut", "ExecutionTimedOut", "Undeliverable", "Terminated",
        }
        if status in terminal:
            stdout = invocation.get("StandardOutputContent", "")
            stderr = invocation.get("StandardErrorContent", "")
            if stdout:
                print(stdout.rstrip(), flush=True)
            if status != "Success":
                if stderr:
                    print(stderr[-4000:], flush=True)
                raise RuntimeError(f"SSM command for {label} ended with {status}")
            return stdout

        elapsed = int(time.monotonic() - (deadline - timeout - 120))
        if elapsed - last_progress >= 60:
            print(f"SSM command for {label} is {status} ({elapsed}s)", flush=True)
            last_progress = elapsed
        time.sleep(POLL_SECONDS)

    raise TimeoutError(f"SSM command for {label} did not finish before the timeout")


def with_target_host(template: str, target_ip: str) -> str:
    return template.replace("@@TARGET_IP@@", target_ip)


def install_replica_helper(instance_id: str) -> None:
    helper_path = Path(__file__).with_name("bootstrap_replica.sh")
    compressed = gzip.compress(helper_path.read_bytes(), compresslevel=9, mtime=0)
    encoded = base64.b64encode(compressed).decode("ascii")
    command = f"""set -Eeuo pipefail
printf '%s' '{encoded}' | base64 --decode | gzip --decompress | sudo tee /usr/local/sbin/bootstrap-private-db-replica >/dev/null
sudo chown root:root /usr/local/sbin/bootstrap-private-db-replica
sudo chmod 0750 /usr/local/sbin/bootstrap-private-db-replica
echo 'REPLICA_HELPER_INSTALLED'
"""
    if len(command) >= 7000:
        raise RuntimeError("Compressed replica helper exceeds the SSM Run Command parameter size limit")
    run_ssm(instance_id, command, "install replica helper", timeout=300)


def wait_for_replica_user_data(instance_id: str) -> None:
    command = r"""#!/usr/bin/env bash
set -uo pipefail
for attempt in $(seq 1 120); do
  health="$(docker inspect --format '{{.State.Health.Status}}' stockspoon-private-db-replica 2>/dev/null || true)"
  if [[ -s /opt/stockspoon-db-private-replica/bootstrap-complete && "$health" == healthy ]]; then
    echo 'PRIVATE_MYSQL_USER_DATA_READY'
    exit 0
  fi
  sleep 10
done
echo 'Private MySQL user-data did not finish with a healthy container within 20 minutes' >&2
cloud-init status --long >&2 || true
tail -n 100 /var/log/cloud-init-output.log >&2 || true
exit 1
"""
    output = run_ssm(instance_id, command, "wait for private MySQL user-data", timeout=1250)
    if "PRIVATE_MYSQL_USER_DATA_READY" not in output:
        raise RuntimeError("Private MySQL user-data did not report readiness")


def main() -> None:
    source_id, source_ip, target_id, target_ip = instance_environment()
    print(f"Checking private replica {target_id} against Primary {source_id}", flush=True)
    wait_for_ssm(source_id)
    wait_for_ssm(target_id)
    wait_for_replica_user_data(target_id)

    install_replica_helper(target_id)

    status = run_ssm(
        target_id,
        f"sudo /usr/local/sbin/bootstrap-private-db-replica status {source_ip}",
        "replica preflight",
        timeout=300,
    )
    if "GTID_REPLICA_THREADS_RUNNING" in status:
        print("Private GTID replica is already connected; binlog replay continues asynchronously", flush=True)
    elif "NEEDS_GTID_CONFIGURATION" in status:
        # A fresh empty replica needs the source's complete GTID history. An
        # already-running replica can safely continue after older source logs
        # have expired because those transactions are already in its GTID set.
        run_ssm(source_id, SOURCE_PREFLIGHT, "verify Primary and retained GTID history", timeout=300)
        run_ssm(
            source_id,
            with_target_host(SOURCE_PREPARE, target_ip),
            "prepare GTID replication account",
            timeout=300,
        )
        run_ssm(
            source_id,
            SOURCE_MONITOR_PREPARE,
            "ensure Primary ProxySQL monitor account",
            timeout=300,
        )
        run_ssm(
            target_id,
            f"sudo /usr/local/sbin/bootstrap-private-db-replica bootstrap {source_ip}",
            "configure GTID auto-position replication",
            timeout=COMMAND_TIMEOUT_SECONDS,
        )
    else:
        raise RuntimeError("Private replica preflight returned an unknown state; refusing to reset it")

    final_status = run_ssm(
        target_id,
        f"sudo /usr/local/sbin/bootstrap-private-db-replica status {source_ip}",
        "verify GTID replication threads",
        timeout=300,
    )
    if "GTID_REPLICA_THREADS_RUNNING" not in final_status:
        raise RuntimeError("Private MySQL did not pass GTID replication thread verification")

    run_ssm(
        source_id,
        with_target_host(SOURCE_DROP_LEGACY_SEED, target_ip),
        "remove obsolete temporary seed account",
        timeout=300,
    )
    print("Private GTID replica configured; available source binlogs are applying asynchronously", flush=True)


if __name__ == "__main__":
    main()
