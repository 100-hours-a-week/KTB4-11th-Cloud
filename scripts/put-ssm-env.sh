#!/usr/bin/env bash
# .env 형식 파일의 KEY=VALUE를 SSM Parameter Store SecureString으로 한 번에 등록합니다.
#   사용법: scripts/put-ssm-env.sh market-streamer /path/to/.env.market-streamer
#   결과:   /stockspoon/v2/prod/market-streamer/<KEY>
# 이미 있는 값은 덮어씁니다. 빈 줄과 # 주석은 건너뜁니다. 값의 앞뒤 따옴표는 제거합니다.
# 값 파일은 레포 밖에 두거나 .env.* 이름을 사용해 커밋되지 않게 합니다. (.gitignore: .env.*)
set -euo pipefail

service="${1:?service name required (e.g. market-streamer)}"
env_file="${2:?env file required}"
prefix="/stockspoon/v2/prod/${service}"

while IFS= read -r line || [[ -n "$line" ]]; do
  [[ -z "${line//[[:space:]]/}" || "$line" =~ ^[[:space:]]*# ]] && continue
  key="${line%%=*}"
  value="${line#*=}"
  key="${key//[[:space:]]/}"
  value="${value%\"}"; value="${value#\"}"
  value="${value%\'}"; value="${value#\'}"

  aws ssm put-parameter --region ap-northeast-2 --type SecureString --overwrite \
    --name "${prefix}/${key}" --value "$value" > /dev/null
  echo "put ${prefix}/${key}"
done < "$env_file"
