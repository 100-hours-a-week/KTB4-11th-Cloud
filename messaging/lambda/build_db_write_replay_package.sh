#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
messaging_dir="$(cd -- "${script_dir}/.." && pwd)"
build_dir="${messaging_dir}/.terraform/db_write_replay_build"

rm -rf "${build_dir}"
mkdir -p "${build_dir}"
if command -v uv >/dev/null 2>&1; then
  uv pip install \
    --no-compile \
    --no-cache \
    --python-version 3.12 \
    --python-platform x86_64-manylinux_2_17 \
    --only-binary=:all: \
    --target "${build_dir}" \
    -r "${script_dir}/db_write_replay_requirements.txt"
else
  python3 -m pip install \
    --disable-pip-version-check \
    --no-compile \
    --no-cache-dir \
    --target "${build_dir}" \
    -r "${script_dir}/db_write_replay_requirements.txt"
fi
cp "${script_dir}/db_write_replay_forwarder.py" "${build_dir}/"
cp "${script_dir}/db_write_business_commands.py" "${build_dir}/"
rm -f "${build_dir}/.lock"
find "${build_dir}" -type d -name __pycache__ -prune -exec rm -rf {} +
find "${build_dir}" -type f -name '*.pyc' -delete

printf 'Lambda package source prepared at %s\n' "${build_dir}"
