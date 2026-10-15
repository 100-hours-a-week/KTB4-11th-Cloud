#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
AGENT_DIRECTORY="/opt/stockspoon-plg-agent"
HOST_ROLE="${1:-}"
LOKI_PRIVATE_IP="${2:-}"

case "$HOST_ROLE" in
  v1)
    MYSQL_CONTAINER="${3:-db}"
    ;;
  migration-db)
    MYSQL_CONTAINER="${3:-migration-mysql}"
    ;;
  *)
    printf '%s\n' 'Usage: sudo bash install.sh <v1|migration-db> <LOKI_PRIVATE_IP> [MYSQL_CONTAINER]' >&2
    exit 2
    ;;
esac

if ! [[ "$LOKI_PRIVATE_IP" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
  printf '%s\n' 'LOKI_PRIVATE_IP must be a private IPv4 address.' >&2
  exit 2
fi
command -v docker >/dev/null
command -v curl >/dev/null
if ! curl --fail --silent "http://$LOKI_PRIVATE_IP:3100/ready" >/dev/null; then
  printf 'Loki is not reachable at %s:3100; check its status and the Security Group rules.\n' "$LOKI_PRIVATE_IP" >&2
  exit 1
fi

MYSQL_DATA_VOLUME="$(docker inspect "$MYSQL_CONTAINER" \
  --format '{{range .Mounts}}{{if eq .Destination "/var/lib/mysql"}}{{.Name}}{{end}}{{end}}')"
if [ -z "$MYSQL_DATA_VOLUME" ]; then
  printf 'Could not find a named /var/lib/mysql volume on container %s.\n' "$MYSQL_CONTAINER" >&2
  exit 1
fi

install -d -m 0750 "$AGENT_DIRECTORY"
cp -a "$SCRIPT_DIR/." "$AGENT_DIRECTORY/"
cat > "$AGENT_DIRECTORY/.env" <<EOF
HOST_ROLE=$HOST_ROLE
LOKI_PUSH_URL=http://$LOKI_PRIVATE_IP:3100/loki/api/v1/push
MYSQL_DATA_VOLUME=$MYSQL_DATA_VOLUME
EOF
chmod 0600 "$AGENT_DIRECTORY/.env"

cd "$AGENT_DIRECTORY"
docker compose --env-file .env -f compose.yaml config --quiet
docker compose --env-file .env -f compose.yaml up -d
ready=false
for attempt in $(seq 1 30); do
  if curl --fail --silent http://127.0.0.1:9100/metrics >/dev/null; then
    ready=true
    break
  fi
  sleep 1
done
if [ "$ready" != true ]; then
  docker compose --env-file .env -f compose.yaml ps
  printf '%s\n' 'Agent readiness check failed; inspect docker compose logs.' >&2
  exit 1
fi
docker compose --env-file .env -f compose.yaml ps
