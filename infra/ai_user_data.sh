#!/usr/bin/env bash
set -Eeuo pipefail

DOCKER_COMPOSE_VERSION="${docker_compose_version}"

export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y docker.io curl ca-certificates
systemctl enable --now docker
usermod -aG docker ubuntu

install -d -m 0755 /usr/local/lib/docker/cli-plugins
curl --fail --silent --show-error --location \
  "https://github.com/docker/compose/releases/download/$DOCKER_COMPOSE_VERSION/docker-compose-linux-x86_64" \
  --output /usr/local/lib/docker/cli-plugins/docker-compose
chmod 0755 /usr/local/lib/docker/cli-plugins/docker-compose

install -d -m 0755 /etc/ssh/sshd_config.d
printf '%s\n' \
  'PasswordAuthentication no' \
  'KbdInteractiveAuthentication no' \
  'PermitRootLogin no' \
  'PubkeyAuthentication yes' \
  'AllowUsers ubuntu' \
  > /etc/ssh/sshd_config.d/99-stockspoon-ai.conf
/usr/sbin/sshd -t
systemctl restart ssh

docker compose version
