#!/usr/bin/env bash
set -Eeuo pipefail
umask 077

SCRIPT_DIRECTORY="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SWITCH_CODE="${SWITCH_CODE:-$SCRIPT_DIRECTORY}"
SWITCH_HOME="${SWITCH_HOME:-$HOME/.stockspoon-switchover}"
CONFIG="$SWITCH_HOME/config.json"
PYTHON="$SWITCH_CODE/.venv/bin/python"

if [[ $# -lt 1 ]]; then
  echo "Usage: $0 <check|capture|switch|rollback> [switchover.py options...]" >&2
  exit 2
fi
if [[ ! -x "$PYTHON" || ! -f "$CONFIG" ]]; then
  echo "Runner isn't prepared. Install dependencies and create $CONFIG first." >&2
  exit 2
fi
command -v aws >/dev/null 2>&1 || { echo "AWS CLI is required." >&2; exit 2; }
command -v session-manager-plugin >/dev/null 2>&1 || { echo "Session Manager plugin is required." >&2; exit 2; }

unset AWS_PROFILE AWS_DEFAULT_PROFILE
aws sts get-caller-identity >/dev/null

mkdir -p "$SWITCH_HOME"
chmod 700 "$SWITCH_HOME"
tunnel_log="$SWITCH_HOME/tunnels-$(date -u +%Y%m%dT%H%M%SZ).log"
"$PYTHON" "$SWITCH_CODE/tunnels_ec2.py" --config "$CONFIG" >"$tunnel_log" 2>&1 &
tunnel_pid=$!

cleanup() {
  if kill -0 "$tunnel_pid" 2>/dev/null; then
    kill -TERM "$tunnel_pid" 2>/dev/null || true
    wait "$tunnel_pid" 2>/dev/null || true
  fi
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

deadline=$((SECONDS + 60))
until grep -q '^READY:' "$tunnel_log"; do
  if ! kill -0 "$tunnel_pid" 2>/dev/null; then
    cat "$tunnel_log" >&2
    echo "ProxySQL tunnels failed; see $tunnel_log" >&2
    exit 1
  fi
  if (( SECONDS >= deadline )); then
    cat "$tunnel_log" >&2
    echo "Timed out waiting for ProxySQL tunnels; see $tunnel_log" >&2
    exit 1
  fi
  sleep 1
done

echo "ProxySQL tunnels are ready. Tunnel log: $tunnel_log"
"$PYTHON" "$SWITCH_CODE/switchover.py" "$@" --config "$CONFIG"
