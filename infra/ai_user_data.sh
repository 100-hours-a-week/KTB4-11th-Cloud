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

# Tailscale 인증 키 가져오기
TAILSCALE_AUTH_KEY=$(aws ssm get-parameter \
  --name "/stockspoon/ai/tailscale-auth-key" \
  --with-decryption \
  --query 'Parameter.Value' \
  --output text \
  --region ap-northeast-2)

# Tailscale 설치
curl -fsSL https://tailscale.com/install.sh | sh
systemctl enable --now tailscaled

# Tailscale 연결
tailscale up \
  --auth-key="$TAILSCALE_AUTH_KEY" \
  --hostname="stockspoon-ai"

# 확인
tailscale status
tailscale ip -4

docker compose version
