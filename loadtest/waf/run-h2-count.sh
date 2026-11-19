#!/usr/bin/env bash
set -uo pipefail

BASE_URL="${BASE_URL:-https://stock-spoon.com}"
K6_SCRIPT="${K6_SCRIPT:-/home/ubuntu/rate-limit.js}"
ACCESS_TOKEN_FILE="${ACCESS_TOKEN_FILE:-/home/ubuntu/.config/stockspoon-k6/waf-user.json}"
RESULT_DIR="${RESULT_DIR:-/home/ubuntu/loadtest-results/http-flood}"
FLOOD_PATH="${FLOOD_PATH:-/api/v1/users/me}"
FLOOD_RPS=3

fail() {
  printf 'ERROR: %s\n' "$1" >&2
  exit 1
}

command -v k6 >/dev/null 2>&1 || fail 'k6 is not installed or not on PATH.'
[[ -r "$K6_SCRIPT" ]] || fail "k6 script is not readable: $K6_SCRIPT"
[[ -s "$ACCESS_TOKEN_FILE" ]] || fail "test token file is missing or empty: $ACCESS_TOKEN_FILE"
[[ "$BASE_URL" == https://* ]] || fail 'BASE_URL must use HTTPS.'
[[ "$FLOOD_PATH" == /api/* ]] || fail 'FLOOD_PATH must start with /api/.'

umask 077
mkdir -p "$RESULT_DIR" || fail "cannot create result directory: $RESULT_DIR"
chmod 700 "$RESULT_DIR" || fail "cannot secure result directory: $RESULT_DIR"

RUN_TAG="$(date -u '+%Y%m%dT%H%M%SZ')"
LOG_FILE="$RESULT_DIR/${RUN_TAG}-h2-count.log"
SUMMARY_FILE="$RESULT_DIR/${RUN_TAG}-h2-count-summary.json"
START_UTC="$(date -u '+%Y-%m-%dT%H:%M:%S.%3NZ')"

{
  printf 'scenario=H2_WAF_COUNT_RATE_MATCH\n'
  printf 'target=%s%s\n' "$BASE_URL" "$FLOOD_PATH"
  printf 'waf_mode_expected=COUNT (this runner does not change AWS WAF)\n'
  printf 'rate_rps=%s\n' "$FLOOD_RPS"
  printf 'duration=6m\n'
  printf 'scheduled_requests=%s\n' "$((FLOOD_RPS * 360))"
  printf 'start_utc=%s\n' "$START_UTC"
} | tee -a "$LOG_FILE"

MODE=flood \
FLOOD_RPS="$FLOOD_RPS" \
FLOOD_PATH="$FLOOD_PATH" \
BASE_URL="$BASE_URL" \
ACCESS_TOKEN_FILE="$ACCESS_TOKEN_FILE" \
k6 run --summary-export "$SUMMARY_FILE" "$K6_SCRIPT" 2>&1 | tee -a "$LOG_FILE"
K6_EXIT_CODE=${PIPESTATUS[0]}

END_UTC="$(date -u '+%Y-%m-%dT%H:%M:%S.%3NZ')"
{
  printf 'end_utc=%s\n' "$END_UTC"
  printf 'k6_exit_code=%s\n' "$K6_EXIT_CODE"
  printf 'k6_log=%s\n' "$LOG_FILE"
  printf 'k6_summary=%s\n' "$SUMMARY_FILE"
} | tee -a "$LOG_FILE"

exit "$K6_EXIT_CODE"
