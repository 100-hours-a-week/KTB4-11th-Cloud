#!/usr/bin/env bash
set -Eeuo pipefail

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

export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y ca-certificates curl gnupg

install -d -m 0755 /usr/share/keyrings
curl --fail --silent --show-error --location https://dl.k6.io/key.gpg \
  | gpg --dearmor --yes -o /usr/share/keyrings/k6-archive-keyring.gpg
chmod 0644 /usr/share/keyrings/k6-archive-keyring.gpg

echo "deb [signed-by=/usr/share/keyrings/k6-archive-keyring.gpg] https://dl.k6.io/deb stable main" \
  > /etc/apt/sources.list.d/k6.list

apt-get update
apt-get install -y k6
k6 version
