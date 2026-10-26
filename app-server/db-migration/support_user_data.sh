#!/usr/bin/env bash
set -Eeuo pipefail

ROLE="${role}"
DOCKER_COMPOSE_VERSION="${docker_compose_version}"
REHEARSAL_DIRECTORY="/opt/stockspoon-db-migration"

export DEBIAN_FRONTEND=noninteractive
apt-get update -o Acquire::Retries=3
apt-get install -y docker.io curl ca-certificates gnupg jq sysstat netcat-openbsd openssl
systemctl enable --now docker
usermod -aG docker ubuntu
timedatectl set-timezone Asia/Seoul

install -d -m 0755 /usr/local/lib/docker/cli-plugins
curl --fail --silent --show-error --location --retry 3 \
  "https://github.com/docker/compose/releases/download/$DOCKER_COMPOSE_VERSION/docker-compose-linux-x86_64" \
  --output /usr/local/lib/docker/cli-plugins/docker-compose
chmod 0755 /usr/local/lib/docker/cli-plugins/docker-compose

if systemctl cat amazon-ssm-agent.service >/dev/null 2>&1; then
  systemctl enable --now amazon-ssm-agent
elif systemctl cat snap.amazon-ssm-agent.amazon-ssm-agent.service >/dev/null 2>&1; then
  systemctl enable --now snap.amazon-ssm-agent.amazon-ssm-agent
else
  snap install amazon-ssm-agent --classic
  systemctl enable --now snap.amazon-ssm-agent.amazon-ssm-agent
fi

install -d -m 0755 /etc/ssh/sshd_config.d
printf '%s\n' \
  'PasswordAuthentication no' \
  'KbdInteractiveAuthentication no' \
  'PermitRootLogin no' \
  'PubkeyAuthentication yes' \
  'AllowUsers ubuntu' \
  > /etc/ssh/sshd_config.d/99-stockspoon.conf
/usr/sbin/sshd -t
systemctl restart ssh

install -d -o ubuntu -g ubuntu -m 0750 \
  "$REHEARSAL_DIRECTORY" \
  "$REHEARSAL_DIRECTORY/scripts" \
  "$REHEARSAL_DIRECTORY/results"

if [ "$ROLE" = "loadgen" ]; then
  install -d -m 0755 /usr/share/keyrings
  curl --fail --silent --show-error --location --retry 3 https://dl.k6.io/key.gpg \
    | gpg --dearmor --yes -o /usr/share/keyrings/k6-archive-keyring.gpg
  chmod 0644 /usr/share/keyrings/k6-archive-keyring.gpg
  printf '%s\n' \
    'deb [signed-by=/usr/share/keyrings/k6-archive-keyring.gpg] https://dl.k6.io/deb stable main' \
    > /etc/apt/sources.list.d/k6.list
  apt-get update -o Acquire::Retries=3
  apt-get install -y k6
  k6 version
fi

if [ "$ROLE" = "pmm" ]; then
  apt-get install -y awscli
  install -d -m 0700 /opt/stockspoon-pmm
  cat > /opt/stockspoon-pmm/docker-compose.yaml <<'COMPOSE'
${pmm_compose}
COMPOSE
  if [ ! -s /opt/stockspoon-pmm/admin-password ]; then
    (umask 077; openssl rand -hex 24 > /opt/stockspoon-pmm/admin-password)
  fi
  cd /opt/stockspoon-pmm
  docker compose up -d
  ready=false
  for attempt in $(seq 1 120); do
    if curl --insecure --fail --silent --output /dev/null \
      https://127.0.0.1:8443/graph/login; then
      ready=true
      break
    fi
    sleep 5
  done
  if [ "$ready" != "true" ]; then
    printf '%s\n' 'PMM did not become ready in time' >&2
    exit 1
  fi
  docker exec migration-pmm-server change-admin-password \
    "$(cat /opt/stockspoon-pmm/admin-password)" >/dev/null
fi

docker compose version
printf '%s\n' "$ROLE bootstrap completed" \
  > "$REHEARSAL_DIRECTORY/bootstrap-complete"
