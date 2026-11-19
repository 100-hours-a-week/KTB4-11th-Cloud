#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
BASE_URL="${BASE_URL:-}"
ROLE="${ROLE:-}"
ATTACK_PROFILE="${ATTACK_PROFILE:-}"
ACCESS_TOKEN_FILE="${ACCESS_TOKEN_FILE:-$HOME/.config/stockspoon-k6/waf-user.json}"
RUN_ID="${RUN_ID:-}"
EVIDENCE_ROOT="${EVIDENCE_ROOT:-$REPO_ROOT/dev/flood-tests}"

fail() {
  printf 'ERROR: %s\n' "$1" >&2
  exit 1
}

command -v k6 >/dev/null 2>&1 || fail 'k6 is not installed or not on PATH.'
[[ -r "$SCRIPT_DIR/flood-mixed.js" ]] || fail 'flood-mixed.js is missing.'
[[ -s "$ACCESS_TOKEN_FILE" ]] || fail "test token file is missing or empty: $ACCESS_TOKEN_FILE"
[[ "$BASE_URL" == https://stock-spoon.com ]] || fail 'Set BASE_URL=https://stock-spoon.com.'
[[ "$ROLE" == normal || "$ROLE" == attack ]] || fail 'ROLE must be normal or attack.'

if [[ "$ROLE" == attack ]]; then
  ATTACK_PROFILE="${ATTACK_PROFILE:-capec_get}"
  [[ "${WAF_MODE_CONFIRMED:-}" == block ]] || fail 'Confirm the deployed Web ACL is in BLOCK mode, then set WAF_MODE_CONFIRMED=block.'
fi

if [[ -z "$RUN_ID" ]]; then
  RUN_ID="$(python3 - <<'PY'
from datetime import datetime
from zoneinfo import ZoneInfo
print(datetime.now(ZoneInfo("Asia/Seoul")).strftime("%Y%m%dT%H%M%S.%f")[:19] + "+0900")
PY
)"
fi
[[ "$RUN_ID" =~ ^[A-Za-z0-9T.+_-]+$ ]] || fail 'RUN_ID contains unsupported characters.'

RUN_LABEL="$ROLE${ATTACK_PROFILE:+-$ATTACK_PROFILE}"
RUN_DIR="$EVIDENCE_ROOT/$RUN_ID/$RUN_LABEL"
RESULT_DIR="$RUN_DIR/k6"
umask 077
mkdir -p "$RUN_DIR" || fail "cannot create evidence directory: $RUN_DIR"
chmod 700 "$RUN_DIR"
cp "$SCRIPT_DIR/flood-mixed.js" "$RUN_DIR/flood-mixed.js"

export RUN_ID RUN_DIR BASE_URL ROLE ATTACK_PROFILE ACCESS_TOKEN_FILE RESULT_DIR
export FLOOD_PATH="${FLOOD_PATH:-/api/v1/users/me}"
export FLOOD_RPS="${FLOOD_RPS:-3}"
export JOURNEY_FLOODS_PER_MINUTE="${JOURNEY_FLOODS_PER_MINUTE:-24}"
export BURST_PEAK_RPS="${BURST_PEAK_RPS:-5}"
export NORMAL_USERS="${NORMAL_USERS:-10}"
export NORMAL_THINK_TIME_SECONDS="${NORMAL_THINK_TIME_SECONDS:-148.6}"
export NORMAL_THINK_JITTER_SECONDS="${NORMAL_THINK_JITTER_SECONDS:-10}"
export NORMAL_INITIAL_JITTER_SECONDS="${NORMAL_INITIAL_JITTER_SECONDS:-20}"
export NORMAL_ACCOUNT_ID="${NORMAL_ACCOUNT_ID:-}"
export NORMAL_PATHS="${NORMAL_PATHS:-}"
export NORMAL_P95_MS="${NORMAL_P95_MS:-1000}"
export WAF_MODE_CONFIRMED="${WAF_MODE_CONFIRMED:-}"

python3 - "$RUN_DIR/scenario.json" <<'PY'
import json
import os
import socket
import sys
from datetime import datetime
from zoneinfo import ZoneInfo

keys = (
    "RUN_ID", "BASE_URL", "ROLE", "ATTACK_PROFILE", "FLOOD_PATH", "FLOOD_RPS",
    "JOURNEY_FLOODS_PER_MINUTE", "BURST_PEAK_RPS", "NORMAL_USERS",
    "NORMAL_THINK_TIME_SECONDS", "NORMAL_THINK_JITTER_SECONDS",
    "NORMAL_INITIAL_JITTER_SECONDS", "NORMAL_ACCOUNT_ID", "NORMAL_PATHS",
    "NORMAL_P95_MS", "WAF_MODE_CONFIRMED", "ACCESS_TOKEN_FILE", "RESULT_DIR",
)
payload = {key.lower(): os.environ.get(key, "") for key in keys}
payload.update({
    "host": socket.gethostname(),
    "created_at_seoul": datetime.now(ZoneInfo("Asia/Seoul")).isoformat(timespec="milliseconds"),
    "k6_script": "flood-mixed.js",
    "traffic_scope": "authenticated read-only HTTP GET requests",
    "token_value_recorded": False,
})
with open(sys.argv[1], "w", encoding="utf-8") as f:
    json.dump(payload, f, ensure_ascii=False, indent=2)
    f.write("\n")
PY
chmod 600 "$RUN_DIR/scenario.json" "$RUN_DIR/flood-mixed.js"

START_MONOTONIC_NS="$(python3 -c 'import time; print(time.monotonic_ns())')"
record_event() {
  local event="$1"
  local exit_code="${2:-}"
  python3 - "$RUN_DIR/run-events.jsonl" "$event" "$exit_code" "$START_MONOTONIC_NS" <<'PY'
import json
import os
import socket
import sys
import time
from datetime import datetime, timezone
from zoneinfo import ZoneInfo

path, event, exit_code, start_ns = sys.argv[1:]
now_ns = time.time_ns()
record = {
    "event": event,
    "run_id": os.environ["RUN_ID"],
    "role": os.environ["ROLE"],
    "attack_profile": os.environ.get("ATTACK_PROFILE", ""),
    "host": socket.gethostname(),
    "time_epoch_ns": now_ns,
    "time_utc": datetime.fromtimestamp(now_ns / 1e9, timezone.utc).isoformat(timespec="milliseconds"),
    "time_seoul": datetime.fromtimestamp(now_ns / 1e9, ZoneInfo("Asia/Seoul")).isoformat(timespec="milliseconds"),
    "monotonic_ns": time.monotonic_ns(),
}
if event == "ended":
    record["exit_code"] = int(exit_code)
    record["duration_ns"] = time.monotonic_ns() - int(start_ns)
with open(path, "a", encoding="utf-8") as f:
    f.write(json.dumps(record, ensure_ascii=False) + "\n")
os.chmod(path, 0o600)
PY
}

record_event started
printf 'RUN_ID=%s\nRUN_DIR=%s\n' "$RUN_ID" "$RUN_DIR"
set +e
"$SCRIPT_DIR/run-local-flood.sh" 2>&1 | tee "$RUN_DIR/runner.log"
exit_code="${PIPESTATUS[0]}"
set -e
record_event ended "$exit_code"
printf 'exit_code=%s\n' "$exit_code"
exit "$exit_code"
