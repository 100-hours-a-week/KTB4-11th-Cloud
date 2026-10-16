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
5. 다음 단계에서 부하 발생기 결과와 실험 시각 기록 도구를 연결한다.

## 장애 감지 알람

- HealthyHostCount < 1: 1분 1회 판정, 데이터 없음도 장애 처리
- Target 5xx > 5%: 요청 20건/분 이상일 때만 판정, 최근 3분 중 2분 초과
- 알람 action은 `observability_alarm_actions`에 명시해야 한다. 기본값은 빈 목록이므로 알람 상태만 표시되며 메일·Discord 등으로 통지하지 않는다.
- FIS를 생성하지 않는다. 향후 실험의 중단 조건에는 `ecs_fault_stop_alarm_arns` output을 사용하고, 시작 전 해당 알람이 OK인지 확인한다.
- 자동 확장 AlarmLow는 저부하에도 ALARM이 되므로 장애 중단 조건으로 사용하지 않는다.
- 완전한 무중단을 판정하는 알람은 아니다. 1분보다 짧은 장애, 저트래픽 장애, 클라이언트에서만 발생하는 실패는 상세 결과와 함께 확인한다.
