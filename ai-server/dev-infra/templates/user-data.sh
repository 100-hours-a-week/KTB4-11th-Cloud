#!/usr/bin/env bash
set -Eeuo pipefail

AWS_REGION="${aws_region}"
DOCKER_COMPOSE_VERSION="${docker_compose_version}"
TAILSCALE_AUTH_PARAMETER="${tailscale_auth_parameter}"
TAILSCALE_HOSTNAME="${tailscale_hostname}"

export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y docker.io curl ca-certificates unzip
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
  > /etc/ssh/sshd_config.d/99-stockspoon-ai-dev.conf
/usr/sbin/sshd -t
systemctl restart ssh

AWS_CLI_WORK_DIR="$(mktemp -d)"
curl --fail --silent --show-error --location \
  "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" \
  --output "$AWS_CLI_WORK_DIR/awscliv2.zip"
unzip -q "$AWS_CLI_WORK_DIR/awscliv2.zip" -d "$AWS_CLI_WORK_DIR"
"$AWS_CLI_WORK_DIR/aws/install" --update
rm -rf "$AWS_CLI_WORK_DIR"

install -d -m 0755 /etc/stockspoon
cat > /etc/stockspoon/ai.env <<'ENVIRONMENT'
AWS_REGION=${aws_region}
REPORT_QUEUE_URL=${report_queue_url}
ORDER_QUEUE_URL=${order_queue_url}
ENVIRONMENT
chmod 0644 /etc/stockspoon/ai.env

TAILSCALE_AUTH_KEY="$(aws ssm get-parameter \
  --name "$TAILSCALE_AUTH_PARAMETER" \
  --with-decryption \
  --query 'Parameter.Value' \
  --output text \
  --region "$AWS_REGION")"

curl -fsSL https://tailscale.com/install.sh | sh
systemctl enable --now tailscaled
tailscale up \
  --auth-key="$TAILSCALE_AUTH_KEY" \
  --hostname="$TAILSCALE_HOSTNAME"
unset TAILSCALE_AUTH_KEY

docker compose version
tailscale status
