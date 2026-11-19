#!/usr/bin/env bash
set -uo pipefail

BASE_URL="${BASE_URL:-}"
ACCESS_TOKEN_FILE="${ACCESS_TOKEN_FILE:-/home/ubuntu/.config/stockspoon-k6/waf-user.json}"
K6_SCRIPT="${K6_SCRIPT:-/home/ubuntu/flood-mixed.js}"
RESULT_DIR="${RESULT_DIR:-/home/ubuntu/loadtest-results/http-flood-mixed}"
NORMAL_LOCAL_IP="${NORMAL_LOCAL_IP:-}"
ATTACK_LOCAL_IPS="${ATTACK_LOCAL_IPS:-}"
ATTACK_PROFILES="${ATTACK_PROFILES:-}"
NORMAL_BASELINE_SECONDS="${NORMAL_BASELINE_SECONDS:-60}"

fail() {
  printf 'ERROR: %s\n' "$1" >&2
  exit 1
}

command -v k6 >/dev/null 2>&1 || fail 'k6 is not installed or not on PATH.'
[[ -r "$K6_SCRIPT" ]] || fail "k6 script is not readable: $K6_SCRIPT"
[[ -s "$ACCESS_TOKEN_FILE" ]] || fail "test token file is missing or empty: $ACCESS_TOKEN_FILE"
[[ "$BASE_URL" == https://* ]] || fail 'Set BASE_URL to the explicitly approved HTTPS target.'
[[ "${WAF_MODE_CONFIRMED:-}" == block ]] || fail 'Confirm the deployed Web ACL is in BLOCK mode, then set WAF_MODE_CONFIRMED=block.'
[[ -n "$NORMAL_LOCAL_IP" ]] || fail 'Set NORMAL_LOCAL_IP to an OS-configured source address.'
[[ -n "$ATTACK_LOCAL_IPS" ]] || fail 'Set ATTACK_LOCAL_IPS to one or more OS-configured source addresses.'
[[ -n "$ATTACK_PROFILES" ]] || fail 'Set ATTACK_PROFILES to match ATTACK_LOCAL_IPS.'

IFS=',' read -r -a attackIps <<< "$ATTACK_LOCAL_IPS"
IFS=',' read -r -a attackProfiles <<< "$ATTACK_PROFILES"
[[ "${#attackIps[@]}" -ge 1 && "${#attackIps[@]}" -le 3 ]] || fail 'Use one through three attack source addresses per run.'
[[ "${#attackIps[@]}" -eq "${#attackProfiles[@]}" ]] || fail 'ATTACK_LOCAL_IPS and ATTACK_PROFILES must have the same number of entries.'
[[ "$NORMAL_BASELINE_SECONDS" =~ ^[0-9]+$ ]] || fail 'NORMAL_BASELINE_SECONDS must be an integer.'
(( NORMAL_BASELINE_SECONDS >= 10 && NORMAL_BASELINE_SECONDS <= 120 )) || fail 'NORMAL_BASELINE_SECONDS must be between 10 and 120.'

declare -A seenIps
seenIps["$NORMAL_LOCAL_IP"]=1
for i in "${!attackIps[@]}"; do
  ip="${attackIps[$i]}"
  profile="${attackProfiles[$i]}"
  [[ -n "$ip" && -z "${seenIps[$ip]:-}" ]] || fail 'Every role must use a different local source address.'
  seenIps["$ip"]=1
  case "$profile" in
    capec_get|journey_flood|burst_flood) ;;
    *) fail "Unsupported ATTACK_PROFILE: $profile" ;;
  esac
done

umask 077
mkdir -p "$RESULT_DIR" || fail "cannot create result directory: $RESULT_DIR"
chmod 700 "$RESULT_DIR" || fail "cannot secure result directory: $RESULT_DIR"

RUN_TAG="$(date -u '+%Y%m%dT%H%M%SZ')"
PIDS=()
LABELS=()

launch_k6() {
  local label="$1"
  local role="$2"
  local localIp="$3"
  local profile="$4"
  local logFile="$RESULT_DIR/${RUN_TAG}-${label}.log"
  local summaryFile="$RESULT_DIR/${RUN_TAG}-${label}-summary.json"

  printf 'Starting %s role=%s local_source=%s profile=%s\n' "$label" "$role" "$localIp" "${profile:-normal}"
  (
    export BASE_URL="$BASE_URL"
    export ACCESS_TOKEN_FILE="$ACCESS_TOKEN_FILE"
    export WAF_MODE_CONFIRMED="block"
    export ROLE="$role"
    export ATTACK_PROFILE="$profile"
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
    exec k6 run --local-ips="$localIp" --summary-export "$summaryFile" "$K6_SCRIPT"
  ) >"$logFile" 2>&1 &
  PIDS+=("$!")
  LABELS+=("$label")
}

stop_children() {
  local pid
  for pid in "${PIDS[@]}"; do
    kill "$pid" 2>/dev/null || true
  done
}
trap 'stop_children; exit 130' INT
trap 'stop_children; exit 143' TERM

{
  printf 'scenario=HTTP_FLOOD_MIXED_NORMAL_AND_ATTACK\n'
  printf 'target=%s\n' "$BASE_URL"
  printf 'waf_mode_confirmation=operator_asserted_BLOCK (runner does not query or change AWS WAF)\n'
  printf 'normal_local_source=%s\n' "$NORMAL_LOCAL_IP"
  printf 'attack_local_sources=%s\n' "$ATTACK_LOCAL_IPS"
  printf 'attack_profiles=%s\n' "$ATTACK_PROFILES"
  printf 'attack_start_delay_seconds=%s\n' "$NORMAL_BASELINE_SECONDS"
  printf 'start_utc=%s\n' "$(date -u '+%Y-%m-%dT%H:%M:%S.%3NZ')"
} | tee "$RESULT_DIR/${RUN_TAG}-run-info.log"

launch_k6 normal normal "$NORMAL_LOCAL_IP" ''
sleep "$NORMAL_BASELINE_SECONDS"
for i in "${!attackIps[@]}"; do
  launch_k6 "attack-$((i + 1))-${attackProfiles[$i]}" attack "${attackIps[$i]}" "${attackProfiles[$i]}"
done

exitCode=0
for i in "${!PIDS[@]}"; do
  if wait "${PIDS[$i]}"; then
    printf 'Completed %s\n' "${LABELS[$i]}"
  else
    childCode=$?
    printf 'Failed %s (exit=%s)\n' "${LABELS[$i]}" "$childCode" >&2
    exitCode=1
  fi
done

printf 'end_utc=%s\n' "$(date -u '+%Y-%m-%dT%H:%M:%S.%3NZ')" | tee -a "$RESULT_DIR/${RUN_TAG}-run-info.log"
exit "$exitCode"
