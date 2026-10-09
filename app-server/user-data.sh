#!/usr/bin/env bash
set -Eeuo pipefail

CLOUD_REPOSITORY_URL="${cloud_repository_url}"
CLOUD_REPOSITORY_BRANCH="${cloud_repository_branch}"
DOCKER_COMPOSE_VERSION="${docker_compose_version}"
CLOUD_DIRECTORY="/opt/cloud"

export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y docker.io git curl ca-certificates
systemctl enable --now docker
usermod -aG docker ubuntu

# Install the Compose v2 CLI plugin at a fixed version so the deployment script
# can use `docker compose` reliably.
install -d -m 0755 /usr/local/lib/docker/cli-plugins
curl --fail --silent --show-error --location \
  "https://github.com/docker/compose/releases/download/$DOCKER_COMPOSE_VERSION/docker-compose-linux-x86_64" \
  --output /usr/local/lib/docker/cli-plugins/docker-compose
chmod 0755 /usr/local/lib/docker/cli-plugins/docker-compose

# Keep SSH key authentication enabled and explicitly reject password/root login.
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

install -d -o ubuntu -g ubuntu -m 0755 "$CLOUD_DIRECTORY"
if [ ! -d "$CLOUD_DIRECTORY/.git" ]; then
  runuser -u ubuntu -- git clone \
    --branch "$CLOUD_REPOSITORY_BRANCH" \
    --single-branch \
    "$CLOUD_REPOSITORY_URL" \
    "$CLOUD_DIRECTORY"
fi

if [ -f "$CLOUD_DIRECTORY/.env.example" ] && [ ! -f "$CLOUD_DIRECTORY/.env" ]; then
  install -o ubuntu -g ubuntu -m 0600 \
    "$CLOUD_DIRECTORY/.env.example" \
    "$CLOUD_DIRECTORY/.env"
fi

chmod +x "$CLOUD_DIRECTORY/scripts/deploy.sh"
docker compose version
