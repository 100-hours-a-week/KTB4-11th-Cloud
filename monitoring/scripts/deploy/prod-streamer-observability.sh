#!/usr/bin/env bash
set -Eeuo pipefail

bundle_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
agent_dir=/opt/stockspoon-ai-telemetry-agent
deploy_dir=/home/ubuntu/ai
dropin_dir=/etc/systemd/system/ktb-market-streamer.service.d
override=$agent_dir/streamer-observability.yaml
dropin=$dropin_dir/observability.conf
backup=$agent_dir/streamer-backup-$(date -u +%Y%m%dT%H%M%SZ)

[[ $(systemctl show ktb-market-streamer.service -p ActiveState --value) == inactive ]]
[[ $(sha256sum "$agent_dir/config.alloy" | cut -d' ' -f1) == "$EXPECTED_ALLOY_SHA256" ]]
! ss -lntH 'sport = :9102' | grep -q .
[[ ! -e $override && ! -e $dropin ]]
cd "$deploy_dir"
image=$(docker compose --env-file .env --env-file .image.env -f compose.prod.yaml config --format json market-streamer | python3 -c 'import json,sys; print(json.load(sys.stdin)["services"]["market-streamer"]["image"])')
docker run --rm --network none --entrypoint /app/.venv/bin/python "$image" -c 'from ktb_telemetry.tracing import tracing; from market_streamer.observability.metrics import MarketMetrics; from market_streamer.observability.tracing import trace_fields; print("Existing image supports metrics and tracing")'
install -d -m 0755 "$dropin_dir"
install -d -m 0700 "$backup"
cp -p "$agent_dir/config.alloy" "$backup/config.alloy"
docker ps --format '{{.ID}} {{.Names}}' | sort > "$backup/containers.before"
systemctl cat ktb-market-streamer.service > "$backup/streamer.service.before"

rollback() {
  cp -p "$backup/config.alloy" "$agent_dir/config.alloy"
  rm -f "$override" "$dropin"
  systemctl daemon-reload
  docker restart stockspoon-ai-alloy >/dev/null
}
trap rollback ERR

install -m 0644 "$bundle_dir/streamer-observability.yaml" "$override"
cat > "$dropin" <<EOF
[Service]
ExecStart=
ExecStart=/usr/bin/flock -n -E 0 $deploy_dir/.market-streamer.lock /usr/bin/docker compose --env-file .env --env-file .image.env -f compose.prod.yaml -f $override run --rm --no-deps --service-ports -T market-streamer
EOF
cd "$deploy_dir"
docker compose --env-file .env --env-file .image.env -f compose.prod.yaml -f "$override" config --quiet market-streamer
cat "$bundle_dir/streamer-metrics.alloy" >> "$agent_dir/config.alloy"
docker exec stockspoon-ai-alloy alloy validate /etc/alloy/config.alloy
systemctl daemon-reload
systemd-analyze verify ktb-market-streamer.service
docker restart stockspoon-ai-alloy >/dev/null
[[ $(systemctl show ktb-market-streamer.service -p ActiveState --value) == inactive ]]
docker ps --format '{{.ID}} {{.Names}}' | sort > "$backup/containers.after"
diff -u "$backup/containers.before" "$backup/containers.after"
trap - ERR
printf 'Applied streamer observability. Backup: %s\n' "$backup"
systemctl show ktb-market-streamer.service -p ExecStart --value
