#!/usr/bin/env bash
set -Eeuo pipefail

DOCKER_COMPOSE_VERSION="${docker_compose_version}"
DB_MIGRATION_DIRECTORY="/opt/stockspoon-db-migration"

export DEBIAN_FRONTEND=noninteractive
apt-get update -o Acquire::Retries=3
apt-get install -y docker.io curl ca-certificates jq sysstat netcat-openbsd
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
  "$DB_MIGRATION_DIRECTORY" \
  "$DB_MIGRATION_DIRECTORY/seed" \
  "$DB_MIGRATION_DIRECTORY/results"

docker version
docker compose version
printf '%s\n' 'DB migration host bootstrap completed' \
  > "$DB_MIGRATION_DIRECTORY/bootstrap-complete"
