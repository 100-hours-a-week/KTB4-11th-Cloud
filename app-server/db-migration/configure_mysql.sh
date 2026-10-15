#!/usr/bin/env bash
set -Eeuo pipefail

MYSQL_BIND_ADDRESS="$1"
PMM_PRIVATE_IP="$2"
MYSQL_DIRECTORY="/opt/stockspoon-db-migration/mysql"
AWS_REGION="${AWS_REGION:-ap-northeast-2}"

if ! [[ "$MYSQL_BIND_ADDRESS" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ \
  && "$PMM_PRIVATE_IP" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  printf '%s\n' 'Expected private IPv4 addresses' >&2
  exit 1
fi

install -d -m 0700 "$MYSQL_DIRECTORY" "$MYSQL_DIRECTORY/secrets"
if [ -f "$MYSQL_DIRECTORY/mysql-bootstrap-complete" ]; then
  docker exec migration-mysql sh -c \
    'MYSQL_PWD="$(cat /run/secrets/mysql_root_password)" exec mysql -uroot -NBe "SELECT VERSION(), @@server_id, @@gtid_mode, @@super_read_only, @@performance_schema"'
  exit 0
fi
export DEBIAN_FRONTEND=noninteractive
apt-get update -o Acquire::Retries=3
apt-get install -y openssl awscli
if [ ! -s "$MYSQL_DIRECTORY/secrets/mysql-root-password" ]; then
  (umask 077; openssl rand -hex 24 > "$MYSQL_DIRECTORY/secrets/mysql-root-password")
fi
if [ ! -s "$MYSQL_DIRECTORY/secrets/pmm-password" ]; then
  (umask 077; openssl rand -hex 24 > "$MYSQL_DIRECTORY/secrets/pmm-password")
fi
printf 'MYSQL_BIND_ADDRESS=%s\n' "$MYSQL_BIND_ADDRESS" > "$MYSQL_DIRECTORY/.env"
chmod 0600 "$MYSQL_DIRECTORY/.env"
cd "$MYSQL_DIRECTORY"
docker compose up -d --wait --wait-timeout 300

PMM_PASSWORD="$(cat secrets/pmm-password)"
docker exec -i migration-mysql sh -c \
  'MYSQL_PWD="$(cat /run/secrets/mysql_root_password)" exec mysql -uroot' <<SQL
SET SESSION sql_log_bin = 0;
SET GLOBAL super_read_only = OFF;
CREATE USER IF NOT EXISTS 'pmm'@'$PMM_PRIVATE_IP' IDENTIFIED BY '$PMM_PASSWORD' WITH MAX_USER_CONNECTIONS 10;
ALTER USER 'pmm'@'$PMM_PRIVATE_IP' IDENTIFIED BY '$PMM_PASSWORD';
ALTER USER 'pmm'@'$PMM_PRIVATE_IP' REQUIRE SSL;
GRANT SELECT, PROCESS, REPLICATION CLIENT, RELOAD ON *.* TO 'pmm'@'$PMM_PRIVATE_IP';
SET PERSIST super_read_only = ON;
SQL

aws ssm put-parameter --region "$AWS_REGION" \
  --name /stockspoon/v1/db-migration/mysql-monitoring \
  --type SecureString --value "file://$MYSQL_DIRECTORY/secrets/pmm-password" \
  --overwrite --query Version --output text

docker exec migration-mysql sh -c \
  'MYSQL_PWD="$(cat /run/secrets/mysql_root_password)" exec mysql -uroot -NBe "SELECT VERSION(), @@server_id, @@gtid_mode, @@super_read_only, @@performance_schema"'
touch "$MYSQL_DIRECTORY/mysql-bootstrap-complete"
