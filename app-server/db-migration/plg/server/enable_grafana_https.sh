#!/usr/bin/env bash
set -Eeuo pipefail

PLG_DIRECTORY="/opt/stockspoon-plg"
GRAFANA_PUBLIC_IP="${1:?Usage: sudo bash enable_grafana_https.sh PUBLIC_IPV4}"
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

if [ "$EUID" -ne 0 ]; then
  printf '%s\n' 'Run this script as root.' >&2
  exit 1
fi
python3 -c 'import ipaddress, sys; ipaddress.IPv4Address(sys.argv[1])' "$GRAFANA_PUBLIC_IP"
test -s "$PLG_DIRECTORY/.env"
command -v openssl >/dev/null

install -d -m 0755 "$PLG_DIRECTORY/https"
install -d -m 0750 -g 101 "$PLG_DIRECTORY/https/tls"
if [ "$SCRIPT_DIR" != "$PLG_DIRECTORY" ]; then
  install -m 0644 "$SCRIPT_DIR/compose.https.yaml" "$PLG_DIRECTORY/compose.https.yaml"
  install -m 0644 "$SCRIPT_DIR/https/nginx.conf" "$PLG_DIRECTORY/https/nginx.conf"
fi

# Public IP 인증서는 IP가 바뀌거나 만료가 가까워진 경우에만 다시 만든다.
CERT="$PLG_DIRECTORY/https/tls/certificate.pem"
KEY="$PLG_DIRECTORY/https/tls/private-key.pem"
if [ ! -s "$CERT" ] || [ ! -s "$KEY" ] \
  || ! openssl x509 -in "$CERT" -noout -checkip "$GRAFANA_PUBLIC_IP" >/dev/null 2>&1 \
  || ! openssl x509 -in "$CERT" -noout -checkend 2592000 >/dev/null 2>&1; then
  openssl req -x509 -newkey rsa:3072 -sha256 -nodes -days 365 \
    -keyout "$KEY" -out "$CERT" \
    -subj "/CN=$GRAFANA_PUBLIC_IP" \
    -addext "subjectAltName=IP:$GRAFANA_PUBLIC_IP" \
    >/dev/null 2>&1
fi
chown root:101 "$KEY" "$CERT"
chmod 0640 "$KEY"
chmod 0644 "$CERT"
printf 'GRAFANA_PUBLIC_IP=%s\n' "$GRAFANA_PUBLIC_IP" > "$PLG_DIRECTORY/https/public.env"
chmod 0644 "$PLG_DIRECTORY/https/public.env"

cd "$PLG_DIRECTORY"
COMPOSE=(docker compose --env-file .env --env-file https/public.env -f compose.yaml -f compose.https.yaml)
"${COMPOSE[@]}" config --quiet
"${COMPOSE[@]}" run --rm --no-deps grafana-https -t
"${COMPOSE[@]}" up -d --no-deps grafana grafana-https

# curl은 자체 서명 인증서를 사용하는 로컬 준비 상태 점검에만 -k를 사용한다.
ready=false
for attempt in $(seq 1 15); do
  if curl --fail --silent --insecure --max-time 3 \
    --resolve "$GRAFANA_PUBLIC_IP:443:127.0.0.1" \
    "https://$GRAFANA_PUBLIC_IP/api/health" >/dev/null; then
    ready=true
    break
  fi
  sleep 2
done
if [ "$ready" != true ]; then
  printf '%s\n' 'Grafana HTTPS health check failed; inspect grafana-https and grafana logs.' >&2
  exit 1
fi
printf 'Grafana HTTPS ready: https://%s/\n' "$GRAFANA_PUBLIC_IP"
printf '%s\n' 'Allow TCP 443 only from the administrator CIDRs in the EC2 security group.'
