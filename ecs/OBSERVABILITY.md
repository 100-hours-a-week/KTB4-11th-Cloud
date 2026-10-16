# ECS 실험 관측 운영 안내

## 구성

- 대시보드: `stockspoon-v2-prod-ecs-experiments`
- 성능 원본 로그: `/aws/ecs/containerinsights/stockspoon-v2-prod-cluster/performance`
- ECS·ASG 이벤트: `/aws/events/stockspoon-v2-prod/lifecycle`
- 실험 마커·클라이언트 지표: `/stockspoon/stockspoon-v2-prod/experiments`
- 관측 로그 보존: 기본 30일. 기존 앱 로그도 기본 30일
- ASG 인스턴스 수 지표: 1분 주기

Container Insights가 이미 생성한 성능 로그 그룹은 import 블록으로 Terraform에 편입한다. 기존 로그를 재생성하지 않는다. 새 클러스터를 처음 만드는 경우에는 로그 그룹이 아직 없으므로 import 블록을 먼저 제거하고 bootstrap해야 한다.

대시보드는 서비스별 CPU·메모리·Task 수, SSE 평균 연결 수, 공유 ASG·Capacity Provider, V1 Blue / V2 Backend / SSE Target Group별 요청·오류·지연·건강 상태를 표시한다. 서비스 로그와 이벤트·실험 마커도 같은 시간 범위에서 조회한다. Auto Scaling 활동 이력은 Application Auto Scaling에서 따로 확인한다. 이벤트는 규칙 적용 이후부터 저장되며 과거 이벤트를 소급 수집하지 않는다.

ECS 배포 이벤트에는 detail.clusterArn이 없으므로 서비스 ARN으로 별도 필터링한다. Task·인스턴스·서비스 이벤트는 detail.clusterArn으로 필터링한다.

## 적용 순서

1. `app-server/TERRAFORM_CI_POLICIES.md`에 따라 CI 관리형 정책 분리를 먼저 준비·적용한다. 새 관측 권한은 observability 정책에 포함된다.
2. `AWS_PROFILE=pattie_for_terraform terraform -chdir=ecs plan`으로 import·로그 보존·대시보드·알람·이벤트 규칙·ASG 지표 변경만 확인한다.
3. plan 검토 후 apply하고 `ecs_experiments_dashboard_url` output으로 접속한다.
4. 기존 ECS Task를 재배포하지 않고, 다음 상태 변경부터 이벤트 수집이 되는지 확인한다. 단순 확인을 위해 운영 Task를 종료하지 않는다.
5. 아래 dry-run부터 검증한 뒤 실험 마커와 k6 결과를 업로드한다.

## 장애 감지 알람

- HealthyHostCount < 1: 1분 1회 판정, 데이터 없음도 장애 처리
- Target 5xx > 5%: 요청 20건/분 이상일 때만 판정, 최근 3분 중 2분 초과
- 알람 action은 `observability_alarm_actions`에 명시해야 한다. 기본값은 빈 목록이므로 알람 상태만 표시되며 메일·Discord 등으로 통지하지 않는다.
- FIS를 생성하지 않는다. 향후 실험의 중단 조건에는 `ecs_fault_stop_alarm_arns` output을 사용하고, 시작 전 해당 알람이 OK인지 확인한다.
- 자동 확장 AlarmLow는 저부하에도 ALARM이 되므로 장애 중단 조건으로 사용하지 않는다.
- 완전한 무중단을 판정하는 알람은 아니다. 1분보다 짧은 장애, 저트래픽 장애, 클라이언트에서만 발생하는 실패는 상세 결과와 함께 확인한다.

## 실험 시각 기록

아래 도구는 부하를 발생시키거나 장애를 주입하지 않는다. 업로더를 실행하는 운영자에는 지정 로그 그룹의 `logs:CreateLogStream`, `logs:PutLogEvents` 권한이 필요하다. 프로필 기본값은 `pattie_for_terraform`이며 별도의 권한 부여는 이 변경에서 수행하지 않는다.

```bash
python3 scripts/ecs_experiment_cloudwatch.py \
  --test-id migration-20261016-01 --service backend --scenario migration --dry-run \
  marker --event start --message 'V1에서 V2로 전환 검증 시작'
```

내용 확인 후 `--dry-run`을 빼면 CloudWatch에 기록한다. 트래픽 비율을 바꿀 때 `--event traffic-shift`, 장애 주입 직전에 `--event fault`, 복구 시 `--event restore`, 종료 시 `--event end`를 같은 test-id로 기록한다. URL·인증 토큰 등 비밀값을 메시지에 포함하지 않는다.

## 클라이언트 결과 업로드

부하 발생기는 별도로 실행한다. k6의 `--out json=<파일>` 원시 JSONL 결과를 사용하며 `--summary-export` 요약 파일은 지원하지 않는다.

```bash
python3 scripts/ecs_experiment_cloudwatch.py \
  --test-id migration-20261016-01 --service backend --scenario migration --dry-run \
  import-k6 --input /tmp/k6-results.jsonl
```

원시 지연 표본을 EMF에 기록해 CloudWatch에서 p95/p99를 계산한다. 분별 p95의 평균을 전체 p95로 사용하지 않는다. 이 도구는 결과 파일의 사후 업로드용이며 테스트 도중 실시간 전송기는 아니다. 파일의 타임스탬프를 유지하므로 대시보드 시간을 실제 테스트 시간으로 설정한다. CloudWatch Logs가 수용하는 최근 타임스탬프 범위 안에서 업로드한다.

| k6 metric 이름 | CloudWatch metric | 단위 |
|---|---|---|
| http_reqs | Requests | Count |
| http_req_failed | Failures | Count |
| http_req_duration | RequestDurationMs | Milliseconds |
| sse_connect_duration_ms | SSEConnectDurationMs | Milliseconds |
| sse_event_gap_ms | SSEEventGapMs | Milliseconds |
| sse_reconnects | SSEReconnects | Count |

SSE의 세 metric은 부하기에서 직접 계측·출력해야 한다. k6 기본 HTTP 지표만으로 SSE 이벤트 공백과 재연결을 측정했다고 간주하지 않는다. SSE 전용 부하 스크립트는 이 변경에 포함하지 않는다.

`ServiceName`(backend/market-http)과 `Scenario`(scaling/migration/fault)만 metric dimension으로 사용한다. TestId는 로그 필드와 stream 이름으로 보존하고 dimension으로 만들지 않는다. 대시보드의 클라이언트 지표는 동일 서비스·시나리오의 동시 실험을 합산하므로 한 번에 하나의 실험을 수행하고 정확한 시간 범위를 선택한다. 상세 로그는 TestId로 필터링한다.

분 단위 서버 지표만으로 무중단을 증명하지 않는다. 부하 발생기의 원시 결과도 보관하고 실패·이벤트 수신 공백을 확인한다. 지표·로그 입력과 저장, Logs Insights 위젯 조회에 CloudWatch 비용이 발생한다.
