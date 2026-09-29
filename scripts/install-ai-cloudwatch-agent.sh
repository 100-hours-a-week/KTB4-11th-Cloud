#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIRECTORY=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
AI_HOST=${1:-}
AI_USER=${AI_SSH_USER:-ubuntu}
AI_SSH_KEY=${AI_SSH_KEY:-}
AGENT_CONFIG="$SCRIPT_DIRECTORY/ai-cloudwatch-agent.json"
REMOTE_CONFIG="/tmp/stockspoon-ai-cloudwatch-agent.json"
SSH_OPTIONS=(
  "-o" "ConnectTimeout=10"
  "-o" "StrictHostKeyChecking=accept-new"
)

if [[ -n "$AI_SSH_KEY" ]]; then
  SSH_OPTIONS+=("-i" "$AI_SSH_KEY")
fi

if [[ -z "$AI_HOST" ]]; then
  echo "Usage: $0 <ai-host>" >&2
  echo "Example: $0 3.39.139.168" >&2
  exit 2
fi

if [[ ! -f "$AGENT_CONFIG" ]]; then
  echo "CloudWatch Agent config not found: $AGENT_CONFIG" >&2
  exit 1
fi

scp "${SSH_OPTIONS[@]}" "$AGENT_CONFIG" "$AI_USER@$AI_HOST:$REMOTE_CONFIG"

ssh "${SSH_OPTIONS[@]}" "$AI_USER@$AI_HOST" 'bash -s' <<'REMOTE_SCRIPT'
set -Eeuo pipefail

PACKAGE_PATH="/tmp/amazon-cloudwatch-agent.deb"
CONFIG_SOURCE="/tmp/stockspoon-ai-cloudwatch-agent.json"
CONFIG_DESTINATION="/opt/aws/amazon-cloudwatch-agent/etc/stockspoon-ai-cloudwatch-agent.json"
AGENT_CONTROL="/opt/aws/amazon-cloudwatch-agent/bin/amazon-cloudwatch-agent-ctl"

curl --fail --silent --show-error --location \
  "https://amazoncloudwatch-agent.s3.amazonaws.com/ubuntu/amd64/latest/amazon-cloudwatch-agent.deb" \
  --output "$PACKAGE_PATH"
sudo dpkg -i -E "$PACKAGE_PATH"
sudo install -o root -g root -m 0644 "$CONFIG_SOURCE" "$CONFIG_DESTINATION"
sudo "$AGENT_CONTROL" \
  -a fetch-config \
  -m ec2 \
  -s \
  -c "file:$CONFIG_DESTINATION"
sudo "$AGENT_CONTROL" -a status
REMOTE_SCRIPT
