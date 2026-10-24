#!/usr/bin/env bash
set -Eeuo pipefail

if [[ "${EUID}" -ne 0 ]]; then
  echo "Run with sudo: sudo bash setup_runner_ec2.sh" >&2
  exit 1
fi

SCRIPT_DIRECTORY="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export DEBIAN_FRONTEND=noninteractive
temporary_directory=""
plugin_package=""
cleanup() {
  [[ -z "$temporary_directory" ]] || rm -rf "$temporary_directory"
  [[ -z "$plugin_package" ]] || rm -f "$plugin_package"
}
trap cleanup EXIT

apt-get update -o Acquire::Retries=3
apt-get install -y ca-certificates curl python3 python3-venv unzip

if ! command -v aws >/dev/null 2>&1 || ! aws --version 2>&1 | grep -q 'aws-cli/2\.'; then
  temporary_directory="$(mktemp -d)"
  case "$(dpkg --print-architecture)" in
    amd64) cli_architecture="x86_64" ;;
    arm64) cli_architecture="aarch64" ;;
    *) echo "Unsupported AWS CLI architecture: $(dpkg --print-architecture)" >&2; exit 1 ;;
  esac
  curl --fail --silent --show-error --location --retry 3 \
    "https://awscli.amazonaws.com/awscli-exe-linux-${cli_architecture}.zip" \
    --output "$temporary_directory/awscliv2.zip"
  unzip -q "$temporary_directory/awscliv2.zip" -d "$temporary_directory"
  "$temporary_directory/aws/install" --update
fi

if ! command -v session-manager-plugin >/dev/null 2>&1; then
  architecture="$(dpkg --print-architecture)"
  case "$architecture" in
    amd64) plugin_architecture="64bit" ;;
    arm64) plugin_architecture="arm64" ;;
    *) echo "Unsupported Session Manager plugin architecture: $architecture" >&2; exit 1 ;;
  esac
  plugin_package="$(mktemp --suffix=.deb)"
  curl --fail --silent --show-error --location --retry 3 \
    "https://s3.amazonaws.com/session-manager-downloads/plugin/latest/ubuntu_${plugin_architecture}/session-manager-plugin.deb" \
    --output "$plugin_package"
  dpkg -i "$plugin_package"
fi

command -v mysqlsh >/dev/null 2>&1 || {
  echo "MySQL Shell is required for the capture command; install mysqlsh 8.4 before using capture." >&2
  exit 1
}

python3 -m venv "$SCRIPT_DIRECTORY/.venv"
"$SCRIPT_DIRECTORY/.venv/bin/python" -m pip install --upgrade pip
"$SCRIPT_DIRECTORY/.venv/bin/python" -m pip install -r "$SCRIPT_DIRECTORY/requirements.txt"

install -d -o ubuntu -g ubuntu -m 0700 /home/ubuntu/.stockspoon-switchover
chown -R ubuntu:ubuntu "$SCRIPT_DIRECTORY/.venv"
chmod 0750 "$SCRIPT_DIRECTORY"
chmod 0600 "$SCRIPT_DIRECTORY/config.ec2.example.json"

aws --version
command -v session-manager-plugin
mysqlsh --version
echo "Manual switchover runner dependencies installed. No database or AWS resources were changed."
