#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
INSTANCE_ID="${1:-}"
HOST_ROLE="${2:-private-replica}"
LOKI_PRIVATE_IP="${3:-10.0.1.85}"
MYSQL_CONTAINER="${4:-stockspoon-private-db-replica}"
AWS_REGION="${AWS_REGION:-ap-northeast-2}"

if ! [[ "$INSTANCE_ID" =~ ^i-[0-9a-f]+$ ]]; then
  printf '%s\n' 'Usage: AWS_PROFILE=stockspoon bash deploy_agent_via_ssm.sh <INSTANCE_ID> [primary|private-replica] [LOKI_PRIVATE_IP] [MYSQL_CONTAINER]' >&2
  exit 2
fi
case "$HOST_ROLE" in
  primary|private-replica) ;;
  *)
    printf '%s\n' 'HOST_ROLE must be primary or private-replica.' >&2
    exit 2
    ;;
esac
if ! [[ "$LOKI_PRIVATE_IP" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
  printf '%s\n' 'LOKI_PRIVATE_IP must be a private IPv4 address.' >&2
  exit 2
fi
command -v aws >/dev/null
command -v python3 >/dev/null
command -v tar >/dev/null

temp_workdir="$(mktemp -d)"
trap 'rm -rf "$temp_workdir"' EXIT
tar --exclude='.DS_Store' -czf "$temp_workdir/agent.tar.gz" -C "$SCRIPT_DIR/agent" .
AGENT_TARBALL_BASE64="$(base64 < "$temp_workdir/agent.tar.gz" | tr -d '\n')"
export INSTANCE_ID HOST_ROLE LOKI_PRIVATE_IP MYSQL_CONTAINER AWS_REGION AGENT_TARBALL_BASE64

python3 - "$temp_workdir/send-command.json" <<'PY'
import json
import os
import shlex
import sys

host_role = os.environ["HOST_ROLE"]
loki_ip = os.environ["LOKI_PRIVATE_IP"]
mysql_container = os.environ["MYSQL_CONTAINER"]
archive = os.environ["AGENT_TARBALL_BASE64"]
commands = [
    "set -Eeuo pipefail",
    "install -d -m 0700 /tmp/stockspoon-plg-agent",
    f"printf '%s' {shlex.quote(archive)} | base64 -d | tar -xz -C /tmp/stockspoon-plg-agent",
]
if host_role == "private-replica":
    commands.append(
        "bash /tmp/stockspoon-plg-agent/configure_replica_monitoring_user.sh "
        f"{shlex.quote(loki_ip)} {shlex.quote(mysql_container)}"
    )
commands.append(
    "bash /tmp/stockspoon-plg-agent/install.sh "
    f"{shlex.quote(host_role)} {shlex.quote(loki_ip)} {shlex.quote(mysql_container)}"
)
request = {
    "DocumentName": "AWS-RunShellScript",
    "InstanceIds": [os.environ["INSTANCE_ID"]],
    "Comment": "Install Stockspoon DB monitoring agent",
    "TimeoutSeconds": 900,
    "Parameters": {"commands": commands},
}
with open(sys.argv[1], "w", encoding="utf-8") as output:
    json.dump(request, output)
PY

command_id="$(aws ssm send-command \
  --region "$AWS_REGION" \
  --cli-input-json "file://$temp_workdir/send-command.json" \
  --query 'Command.CommandId' --output text)"
printf 'SSM command: %s\n' "$command_id"

if ! aws ssm wait command-executed \
  --region "$AWS_REGION" \
  --command-id "$command_id" \
  --instance-id "$INSTANCE_ID"; then
  aws ssm get-command-invocation \
    --region "$AWS_REGION" \
    --command-id "$command_id" \
    --instance-id "$INSTANCE_ID" \
    --query '{Status:Status,StatusDetails:StatusDetails,Stdout:StandardOutputContent,Stderr:StandardErrorContent}' \
    --output json
  exit 1
fi

aws ssm get-command-invocation \
  --region "$AWS_REGION" \
  --command-id "$command_id" \
  --instance-id "$INSTANCE_ID" \
  --query '{Status:Status,StatusDetails:StatusDetails,Stdout:StandardOutputContent,Stderr:StandardErrorContent}' \
  --output json
