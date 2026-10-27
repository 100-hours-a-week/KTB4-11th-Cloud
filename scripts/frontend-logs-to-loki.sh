#!/usr/bin/env bash
# 운영 FE 서비스의 로그 드라이버를 awslogs → json-file로 바꿔 CloudWatch 수집을 멈춥니다.
#   사용법: scripts/frontend-logs-to-loki.sh           # 변경 미리보기만 (기본)
#           scripts/frontend-logs-to-loki.sh --apply   # 새 revision 등록 + 롤링 배포
# 로그는 Alloy가 Docker json-file을 읽어 Loki로 계속 보냅니다. CloudWatch 로그 그룹과 기존 기록은 지우지 않습니다.
# FE CD는 최신 revision을 복사해 이미지만 바꾸므로, 한 번 바꾸면 이후 배포에도 유지됩니다.
set -euo pipefail

cluster="stockspoon-v2-prod-cluster"
service="stockspoon-v2-prod-frontend"
region="ap-northeast-2"
apply="${1:-}"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

current="$(aws ecs describe-services --region "$region" --cluster "$cluster" --services "$service" \
  --query 'services[0].taskDefinition' --output text)"
aws ecs describe-task-definition --region "$region" --task-definition "$current" \
  --query 'taskDefinition' --output json > "$work/source.json"

driver="$(jq -r '.containerDefinitions[] | select(.name == "frontend") | .logConfiguration.logDriver' "$work/source.json")"
if [[ "$driver" == "json-file" ]]; then
  echo "이미 json-file입니다: $current"
  exit 0
fi

# FE CD와 같은 필드를 제거하고 frontend 컨테이너의 logConfiguration만 바꿉니다.
jq 'del(.taskDefinitionArn, .revision, .status, .requiresAttributes, .compatibilities, .registeredAt, .registeredBy, .deregisteredAt)' \
  "$work/source.json" > "$work/base.json"
jq '(.containerDefinitions[] | select(.name == "frontend") | .logConfiguration)
    = {logDriver: "json-file", options: {"max-size": "10m", "max-file": "5"}}' \
  "$work/base.json" > "$work/next.json"

echo "현재 revision: $current"
diff <(jq -S . "$work/base.json") <(jq -S . "$work/next.json") || true

if [[ "$apply" != "--apply" ]]; then
  echo "미리보기만 했습니다. 적용하려면 --apply를 붙여 다시 실행하세요."
  exit 0
fi

next="$(aws ecs register-task-definition --region "$region" --cli-input-json "file://$work/next.json" \
  --query 'taskDefinition.taskDefinitionArn' --output text)"
echo "등록: $next"
aws ecs update-service --region "$region" --cluster "$cluster" --service "$service" \
  --task-definition "$next" > /dev/null
echo "롤링 배포 대기 중 (circuit breaker가 실패 시 자동 롤백)..."
aws ecs wait services-stable --region "$region" --cluster "$cluster" --services "$service"
echo "완료: $service → $next"
