#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
K6_SCRIPT="${K6_SCRIPT:-$SCRIPT_DIR/flood-mixed.js}"
BASE_URL="${BASE_URL:-}"
ACCESS_TOKEN_FILE="${ACCESS_TOKEN_FILE:-$HOME/.config/stockspoon-k6/waf-user.json}"
RESULT_DIR="${RESULT_DIR:-$HOME/.local/state/stockspoon-k6/http-flood}"
ROLE="${ROLE:-attack}"
ATTACK_PROFILE="${ATTACK_PROFILE:-}"

fail() {
  printf 'ERROR: %s\n' "$1" >&2
  exit 1
}

command -v k6 >/dev/null 2>&1 || fail 'k6 is not installed or not on PATH.'
[[ -r "$K6_SCRIPT" ]] || fail "k6 script is not readable: $K6_SCRIPT"
[[ -s "$ACCESS_TOKEN_FILE" ]] || fail "test token file is missing or empty: $ACCESS_TOKEN_FILE"
[[ "$BASE_URL" == https://* ]] || fail 'Set BASE_URL to the HTTPS viewer URL to test.'
[[ "$ROLE" == normal || "$ROLE" == attack ]] || fail 'ROLE must be normal or attack.'

if [[ "$ROLE" == attack ]]; then
  ATTACK_PROFILE="${ATTACK_PROFILE:-capec_get}"
  [[ "${WAF_MODE_CONFIRMED:-}" == block ]] || fail 'Confirm the deployed CloudFront Web ACL is in BLOCK mode, then set WAF_MODE_CONFIRMED=block.'
  case "$ATTACK_PROFILE" in
    capec_get|journey_flood|burst_flood) ;;
    *) fail 'ATTACK_PROFILE must be capec_get, journey_flood, or burst_flood.' ;;
  esac
fi

umask 077
mkdir -p "$RESULT_DIR" || fail "cannot create result directory: $RESULT_DIR"
chmod 700 "$RESULT_DIR" || fail "cannot secure result directory: $RESULT_DIR"

RUN_TAG="$(date -u '+%Y%m%dT%H%M%SZ')"
LOG_FILE="$RESULT_DIR/${RUN_TAG}-${ROLE}${ATTACK_PROFILE:+-$ATTACK_PROFILE}.log"
SUMMARY_FILE="$RESULT_DIR/${RUN_TAG}-${ROLE}${ATTACK_PROFILE:+-$ATTACK_PROFILE}-summary.json"

{
  printf 'scenario=LOCAL_HTTP_FLOOD\n'
  printf 'target=%s\n' "$BASE_URL"
  printf 'role=%s\n' "$ROLE"
  printf 'attack_profile=%s\n' "${ATTACK_PROFILE:-none}"
  if [[ "$ROLE" == attack ]]; then
    printf 'waf_mode_confirmation=operator_asserted_BLOCK (runner does not query or change AWS WAF)\n'
  fi
  printf 'start_utc=%s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
} > "$RESULT_DIR/${RUN_TAG}-run-info.log"

export BASE_URL ACCESS_TOKEN_FILE ROLE ATTACK_PROFILE
export WAF_MODE_CONFIRMED="${WAF_MODE_CONFIRMED:-}"
export NORMAL_USERS="${NORMAL_USERS:-10}"
export NORMAL_THINK_TIME_SECONDS="${NORMAL_THINK_TIME_SECONDS:-148.6}"
export NORMAL_THINK_JITTER_SECONDS="${NORMAL_THINK_JITTER_SECONDS:-10}"
export NORMAL_INITIAL_JITTER_SECONDS="${NORMAL_INITIAL_JITTER_SECONDS:-20}"
export NORMAL_ACCOUNT_ID="${NORMAL_ACCOUNT_ID:-}"
export NORMAL_PATHS="${NORMAL_PATHS:-}"
export NORMAL_P95_MS="${NORMAL_P95_MS:-1000}"
export FLOOD_PATH="${FLOOD_PATH:-/api/v1/users/me}"
export FLOOD_RPS="${FLOOD_RPS:-3}"
export JOURNEY_FLOODS_PER_MINUTE="${JOURNEY_FLOODS_PER_MINUTE:-24}"
export BURST_PEAK_RPS="${BURST_PEAK_RPS:-5}"

printf 'Log: %s\nSummary: %s\n' "$LOG_FILE" "$SUMMARY_FILE"
k6 run --summary-export "$SUMMARY_FILE" "$K6_SCRIPT" 2>&1 | tee "$LOG_FILE"
