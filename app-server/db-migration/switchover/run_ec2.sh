#!/usr/bin/env bash
set -Eeuo pipefail
umask 077

SCRIPT_DIRECTORY="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SWITCH_CODE="${SWITCH_CODE:-$SCRIPT_DIRECTORY}"
SWITCH_HOME="${SWITCH_HOME:-$HOME/.stockspoon-switchover}"
CONFIG="$SWITCH_HOME/config.json"
CREDENTIALS="$SWITCH_HOME/credentials.json"
PYTHON="$SWITCH_CODE/.venv/bin/python"

usage() {
  cat >&2 <<EOF
Usage: $0 <check|capture|switch|rollback|restore|setup-passwords> [switchover.py options...]

The first operation collects passwords once into $CREDENTIALS (mode 0600).
Output directories are generated automatically. switch uses the newest successful
capture, and rollback uses the newest successful switch unless explicitly provided.
EOF
}

if [[ $# -lt 1 ]]; then
  usage
  exit 2
fi
command_name="$1"
shift
if [[ ! -x "$PYTHON" || ! -f "$CONFIG" ]]; then
  echo "Runner isn't prepared. Install dependencies and create $CONFIG first." >&2
  exit 2
fi

mkdir -p "$SWITCH_HOME"
chmod 700 "$SWITCH_HOME"

if [[ "$command_name" == "setup-passwords" ]]; then
  "$PYTHON" "$SWITCH_CODE/credential_store.py" setup --config "$CONFIG" --file "$CREDENTIALS"
  exit $?
fi

case "$command_name" in
  check|capture|switch|rollback|restore) ;;
  *) usage; exit 2 ;;
esac

if [[ ! -f "$CREDENTIALS" ]]; then
  echo "First use: enter each required password once; later runs reuse the protected file." >&2
  "$PYTHON" "$SWITCH_CODE/credential_store.py" setup --config "$CONFIG" --file "$CREDENTIALS"
fi
"$PYTHON" "$SWITCH_CODE/credential_store.py" validate --config "$CONFIG" --file "$CREDENTIALS"

args=("$@")
has_option() {
  local option="$1"
  shift
  local argument
  for argument in "$@"; do
    [[ "$argument" == "$option" || "$argument" == "$option="* ]] && return 0
  done
  return 1
}

latest_record() {
  "$PYTHON" - "$SWITCH_HOME" "$1" <<'PY'
import json
import sys
from pathlib import Path

root = Path(sys.argv[1])
expected = sys.argv[2]
records = []
for directory in root.glob(expected + "-*"):
    state_file = directory / "state.json"
    try:
        state = json.loads(state_file.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError):
        continue
    if state.get("command") == expected and state.get("status") == "complete":
        records.append((state.get("started_at", ""), directory))
if not records:
    raise SystemExit(f"No successful {expected} record found under {root}")
print(max(records, key=lambda item: item[0])[1])
PY
}

if [[ "$command_name" == "switch" ]] && ! has_option --capture-dir "${args[@]}"; then
  capture_dir="$(latest_record capture)"
  echo "Using latest successful capture: $capture_dir"
  args+=(--capture-dir "$capture_dir")
fi
if [[ "$command_name" == "rollback" || "$command_name" == "restore" ]] \
    && ! has_option --switch-dir "${args[@]}"; then
  switch_dir="$(latest_record switch)"
  echo "Using latest successful switch: $switch_dir"
  args+=(--switch-dir "$switch_dir")
fi

output_command="$command_name"
[[ "$output_command" != "restore" ]] || output_command=rollback
output_directory=""
if ! has_option --out "${args[@]}"; then
  output_directory="$SWITCH_HOME/${output_command}-$(date -u +%Y%m%dT%H%M%SZ)-$$"
  args+=(--out "$output_directory")
else
  for ((index = 0; index < ${#args[@]}; index++)); do
    if [[ "${args[index]}" == "--out" ]]; then
      output_directory="${args[index + 1]:-}"
      break
    elif [[ "${args[index]}" == --out=* ]]; then
      output_directory="${args[index]#--out=}"
      break
    fi
  done
fi
echo "Run record: $output_directory"

command -v aws >/dev/null 2>&1 || { echo "AWS CLI is required." >&2; exit 2; }
command -v session-manager-plugin >/dev/null 2>&1 || { echo "Session Manager plugin is required." >&2; exit 2; }
unset AWS_PROFILE AWS_DEFAULT_PROFILE
aws sts get-caller-identity >/dev/null

tunnel_log="$SWITCH_HOME/tunnels-$(date -u +%Y%m%dT%H%M%SZ)-$$.log"
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

cat "$tunnel_log"
"$PYTHON" "$SWITCH_CODE/switchover.py" "$command_name" "${args[@]}" \
  --config "$CONFIG" --credentials-file "$CREDENTIALS"
