#!/usr/bin/env bash
set -Eeuo pipefail

AWS_REGION="${aws_region}"
DOCKER_COMPOSE_VERSION="${docker_compose_version}"
ROOT_PASSWORD_PARAMETER="${root_password_parameter}"
MYSQL_DIRECTORY="/opt/stockspoon-db-private-replica"

export DEBIAN_FRONTEND=noninteractive
apt-get update -o Acquire::Retries=3
apt-get install -y awscli ca-certificates curl docker.io gzip jq netcat-openbsd openssl
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

install -d -m 0700 "$MYSQL_DIRECTORY/secrets"
for attempt in $(seq 1 30); do
  if aws ssm get-parameter --region "$AWS_REGION" --name "$ROOT_PASSWORD_PARAMETER" \
    --with-decryption --query 'Parameter.Value' --output text \
    > "$MYSQL_DIRECTORY/secrets/mysql-root-password"; then
    break
  fi
  if [[ "$attempt" -eq 30 ]]; then
    echo "Unable to retrieve $ROOT_PASSWORD_PARAMETER after retrying" >&2
    exit 1
  fi
  sleep 10
done
chmod 0600 "$MYSQL_DIRECTORY/secrets/mysql-root-password"

cat > "$MYSQL_DIRECTORY/docker-compose.yaml" <<'COMPOSE'
${mysql_compose}
COMPOSE
chown -R root:root "$MYSQL_DIRECTORY"
chmod 0600 "$MYSQL_DIRECTORY/docker-compose.yaml"

cd "$MYSQL_DIRECTORY"
docker compose up -d --wait --wait-timeout 300
docker exec stockspoon-private-db-replica sh -lc \
  'MYSQL_PWD="$(cat /run/secrets/mysql_root_password)" exec mysql --no-defaults --protocol=TCP --host=127.0.0.1 --port=3306 --connect-timeout=2 --user=root --batch --skip-column-names --execute="SELECT VERSION(), @@server_id, @@gtid_mode"'

printf '%s\n' 'Private DB replica bootstrap completed' > "$MYSQL_DIRECTORY/bootstrap-complete"
