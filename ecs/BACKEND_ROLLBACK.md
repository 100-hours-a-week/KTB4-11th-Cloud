# Backend V1 자동 롤백

운영 `/api/*`의 V2 오류를 CloudWatch가 감지하면 EventBridge → Lambda가 기존 ALB 규칙을 **V1 100 / V2 0**으로 변경한다. ECS 배포 Circuit Breaker와 별개로, EC2 V1으로 트래픽을 복구하는 기능이다. DB나 BE 코드, SSE 라우팅은 변경하지 않는다.

현재 코드의 희망 V2 가중치는 100이다. 처음 구성할 때 SSM 상태를 `disarmed`로 생성하므로 컨트롤러가 트래픽을 변경하지 않는다. V1이 실제 요청을 정상 처리하는지 확인한 다음 운영자가 활성화한다.

## 감지와 동작

| 조건 | 기준 |
|---|---|
| V2 정상 타깃 부재 | HealthyHostCount Maximum < 1, 1분 구간 2회 연속 |
| V2 애플리케이션 5xx | 분당 요청 ≥ 5, 5xx ≥ 3, 오류율 > 5%, 1분 구간 2회 연속 |
| 누락된 지표 | 자동으로 장애로 간주하지 않음 |
| V1 복구 대상 확인 | DescribeTargetHealth에서 V1 healthy 타깃 최소 1개 |
| 재확인 | 1분마다 현재 알람과 롤백 상태 확인 |

3 RPS에서 V2 10%의 평균 요청량은 약 18회/분이므로 기존 운영 알람의 20회 제한과 별도로 낮은 요청량용 알람을 둔다. 오류 최소 3회 조건 때문에 저빈도 오류를 전부 감지하는 정책은 아니다. ALB 자체 502/504, 응답 내용 불일치, 인증 4xx, 지연만 증가하는 장애는 이 정책의 직접 감지 대상이 아니다. 클라이언트 관점의 검증은 k6로 병행한다. 감지는 분 단위 집계와 알람 평가 지연이 있으므로 즉시 복구나 오류 0건을 보장하지 않는다.

Lambda는 이벤트의 계정·리전·알람을 검증하고 현재 알람 상태를 재조회한다. ALARM 이벤트가 늦게 도착했더라도 이미 정상 복구됐으면 새 롤백을 시작하지 않는다. 지정한 규칙과 V1/V2 타깃 그룹만 수정하고 경로나 우선순위는 유지한다. V1 타깃이 unhealthy이면 복구를 차단하고 오류를 기록한다. healthy 확인은 헬스체크 결과이므로 실제 프로필 조회의 성공까지 보증하지는 않는다.

Lambda는 예약 동시성을 설정하지 않고 계정 공용 동시 실행 용량을 사용한다. 현재 계정의 서울 리전 한도는 총 10개이며, 최소 공용 용량 10개를 남겨야 하므로 1개 예약도 거절된다. 중복 이벤트는 같은 V1 100 / V2 0 가중치로 수렴한다. 공용 용량이 고갈되면 호출이 지연될 수 있으므로 대시보드의 Throttles와 실패 큐를 확인한다. 감시 상태 변경·재전환 중에는 처리 중인 롤백이 없는지 확인한다.

## 롤백 상태와 Terraform

SSM: `/stockspoon/operations/prod/backend-routing/rollback-latch` (비밀이 아닌 String)

| 값 | 동작 |
|---|---|
| `disarmed` | 자동 롤백 비활성. Terraform은 코드의 희망 가중치 사용 |
| `armed` | 알람을 감시하며 코드의 희망 가중치 사용 |
| `tripped` | 롤백 실행 상태. Terraform의 실제 V2 가중치를 0으로 유지 |

Terraform은 파라미터를 생성하고 값은 `ignore_changes`로 운영자/Lambda에 맡긴다. Lambda는 ALB 변경 **전에** `tripped`를 저장한다. 이후 변경 API가 실패해도 재시도와 다음 1분 점검에서 복구를 재시도한다. 정상 상태로 돌아와도 자동으로 재승격하지 않는다.

롤백 직후에는 **이전에 저장한 plan을 모두 폐기하고 새 plan을 생성한다.** SSM 변경은 Terraform state 쓰기가 아니므로 기존 plan이 자동으로 stale 판정을 받는다고 가정하면 안 된다. 기존 plan이나 동시에 실행된 apply가 V2로 돌릴 수 있고, 1분 재확인이 다시 V1으로 복구하기까지 노출 구간이 생긴다. 실험 중에는 CI apply와 로컬 apply를 동시에 실행하지 않는다. 롤백 상태로 fresh plan을 만들면 희망값이 100이어도 실제 가중치는 0이다.

`backend_auto_rollback_enabled=false`는 컨트롤러와 상태를 제거하므로 보호 기능 해제와 희망 가중치 재적용이 함께 일어난다. 일반적인 감시 일시 중지는 아래의 `disarmed`를 사용하되, 이미 롤백된 경우 먼저 코드의 희망 가중치를 0으로 맞춰야 한다.

## 적용 순서

아래는 저장소 루트에서 실행한다. 운영자가 plan을 확인한 뒤 apply한다. PR merge 전 CI 정책을 먼저 반영해야 새 리소스 조회/관리가 가능하다.

### 1. CI 정책만 로컬 적용

```bash
export AWS_PROFILE=stockspoon
terraform -chdir=app-server plan \
  -target=aws_iam_policy.github_actions_terraform_read \
  '-target=aws_iam_policy.terraform_ci_write["application"]' \
  -out=/tmp/backend-rollback-ci.tfplan
terraform -chdir=app-server show -no-color /tmp/backend-rollback-ci.tfplan
# 기대: 정책 2개 수정, 추가/삭제 없음
terraform -chdir=app-server apply /tmp/backend-rollback-ci.tfplan
```

새 SSM 파라미터 1개에만 조회·쓰기 권한을 추가하고, 기존 Lambda 이름 범위에 동시성·비동기 재시도 설정 권한을 추가한다. IAM 사용자 권한을 별도로 넓히지 않는다.

### 2. 자동 롤백 구성

```bash
terraform -chdir=ecs init -input=false
terraform -chdir=ecs plan -out=/tmp/backend-rollback.tfplan
terraform -chdir=ecs show -no-color /tmp/backend-rollback.tfplan
```

2026-10-17 검토 plan은 자동 롤백 리소스 18개 생성 외에 기존 ECS 권장 AMI 변경에 따른 Launch Template/ASG 수정 2개를 포함한다. 전용 대시보드(`stockspoon-v2-prod-backend-rollback`)에 롤백 알람·실행 로그·컨트롤러 실패·V1/V2 요청량을 표시한다. **이 전체 plan을 그대로 적용하지 않는다.** 이번 실험의 자동 롤백만 적용하려면 아래 대상 지정 plan을 새로 만든다. 일반 운영의 전체 plan에 남는 AMI 변경은 별도로 검토한다.

```bash
terraform -chdir=ecs plan \
  -target=aws_lambda_function_event_invoke_config.backend_rollback \
  -target=aws_cloudwatch_event_target.backend_rollback \
  -target=aws_cloudwatch_metric_alarm.backend_rollback_controller_errors \
  -target=aws_cloudwatch_dashboard.backend_rollback \
  -out=/tmp/backend-rollback-only.tfplan
terraform -chdir=ecs show -no-color /tmp/backend-rollback-only.tfplan
# 기대: 자동 롤백 리소스 18개 생성(전용 대시보드 포함), 기존 ALB/EC2/ECS 서비스 변경·삭제 없음
terraform -chdir=ecs apply /tmp/backend-rollback-only.tfplan
terraform -chdir=ecs output backend_auto_rollback
```

target 옵션은 검토된 실험 변경을 분리하기 위한 한시적 사용이다. 출력 갱신이 일부 누락될 수 있으므로 실제 상태는 AWS 조회로도 확인한다. 적용 후 전체 plan을 다시 확인하되 관련 없는 변경을 그대로 apply하지 않는다.

### 3. 활성화 전에 확인

V1 타깃 healthy, V1 100% 구간에서 프로필 조회 정상, 새 롤백 알람 두 개 모두 OK인지 확인한다. 아래 명령은 읽기 전용이다.

```bash
aws cloudwatch describe-alarms --region ap-northeast-2 \
  --alarm-names stockspoon-v2-prod-backend-rollback-5xx stockspoon-v2-prod-backend-rollback-unhealthy \
  --query 'MetricAlarms[].{Name:AlarmName,State:StateValue}'
aws ssm get-parameter --region ap-northeast-2 \
  --name /stockspoon/operations/prod/backend-routing/rollback-latch \
  --query Parameter.Value --output text
```

활성화 명령은 AWS 설정 변경이다. 감시를 켜면 이미 ALARM인 경우에도 다음 1분 점검에서 복구할 수 있으므로 선행 확인을 생략하지 않는다.

```bash
aws ssm put-parameter --region ap-northeast-2 \
  --name /stockspoon/operations/prod/backend-routing/rollback-latch \
  --type String --value armed --overwrite
```

## 검증은 두 단계로 구분

1. **연결 검증:** V2에 일부 트래픽이 전달되는 상태에서 k6 조회 부하 중 운영자 승인 후 `set-alarm-state`로 전용 알람 한 개를 ALARM으로 변경한다. EventBridge, Lambda, V1 복구, `tripped`, Lambda 완료 로그, k6 결과를 확인한다. 지표 평가가 수동 상태를 빠르게 덮어쓸 수 있어 Lambda의 재조회 전에 OK가 되면 롤백하지 않는 것이 정상이다. 이 검증은 실제 장애 감지를 입증하지 않는다.
2. **실제 장애 검증:** 별도 승인한 V2 전용 장애를 발생시키고 실제 CloudWatch 지표로 알람이 전환되어 복구되는지 관찰한다. V1 EC2/DB는 건드리지 않는다. 장애 주입 명령과 k6 스크립트는 검토 후 따로 준비한다. 현재 프로필 테스트가 첫 실패에 중단되는 스크립트라면, 오류와 복구를 끝까지 기록하는 검증용 스크립트를 먼저 검토해야 한다.

```bash
# 운영자가 연결 검증을 승인하고 실행할 때만 사용
aws cloudwatch set-alarm-state --region ap-northeast-2 \
  --alarm-name stockspoon-v2-prod-backend-rollback-5xx \
  --state-value ALARM --state-reason 'Approved backend routing rollback wiring test'

# 읽기 전용: 실행 기록
aws logs tail /aws/lambda/stockspoon-v2-prod-backend-rollback \
  --region ap-northeast-2 --since 15m --format short
```

`rollback_completed`는 ALB API가 V1 100 / V2 0을 반환한 시점이다. 실제 클라이언트 복구 시간은 k6 요청의 첫 오류와 이후 정상 응답 시각으로 계산한다. EventBridge는 타깃 전달 실패를, Lambda는 처리 실패를 재시도한다. 최대 재시도 후 실패 이벤트는 SQS `stockspoon-v2-prod-backend-rollback-failures`에 보존한다(14일). 1분 점검도 계속 동작한다.

Lambda 로그는 30일 보존한다. `...-controller-errors` 알람에서 컨트롤러 실패를 확인한다. `observability_alarm_actions` 기본값은 빈 목록이라 푸시 알림은 없으며, 알람 상태와 로그를 직접 확인한다. failure queue는 자동 소비하지 않으므로 메시지가 있으면 원인을 확인하고 처리한다.

포트폴리오에는 장애/알람 시각, V1 복구 시각, 오류 건수, k6 회복 시각, V1/V2 요청량 그래프를 함께 남긴다. 연결 검증과 실제 장애 검증 결과를 구분해서 기록한다.

## 복구 후 재전환

1. 코드 `backend_canary_green_weight`를 0으로 맞추고 새로운 plan/apply로 코드와 V1 운영 상태를 일치시킨다. `tripped`는 유지한다.
2. V2를 수리하고 두 전용 알람이 OK인지 확인한다.
3. 위의 `put-parameter --value armed`로 재활성화한다. 이 시점 코드의 희망값이 0이어야 한다.
4. 희망 V2 가중치를 10 → 50 → 100으로 바꾸면서 단계별 새 plan/apply와 k6 검증을 수행한다.

이미 롤백된 상태에서 코드가 100인 채 파라미터를 `armed`/`disarmed`로 바꾸면 다음 apply가 V2 100을 재적용할 수 있다. 파라미터 상태만 되돌려서 재전환하지 않는다.

## 로컬 검증

```bash
python3 -m unittest discover -s ecs/tests -v
terraform -chdir=ecs validate
terraform -chdir=app-server validate
```

테스트는 정상 복구, 중복 이벤트, V1 unhealthy, 잘못된 이벤트, SSM 저장 실패, ALB 변경 실패, 저장된 롤백 상태 재확인과 원치 않는 타깃 덮어쓰기 방지를 검증한다. 실제 AWS 적용/장애 검증은 별도다.
