# BE 모니터링 변경 사항 및 개선 계획

기준일: 2026-11-03  
운영 상태: BE 지표 수집, Grafana 대시보드 반영, Tempo 요청-DB trace 연결 확인 완료

## 적용 범위

Cloud 저장소 [PR #294](https://github.com/100-hours-a-week/KTB4-11th-Cloud/pull/294)에서 BE 관측 구성을 확장했고, BE 저장소의 [PR #237](https://github.com/100-hours-a-week/KTB4-11th-BE/pull/237), [PR #238](https://github.com/100-hours-a-week/KTB4-11th-BE/pull/238)을 통해 운영 태스크 설정과 Java agent 실행 문제를 보완했다.

운영 BE Grafana 대시보드는 UID `stockspoon-prod-backend`이며 18개 패널로 구성된다.

- API URI 템플릿별 요청량, 평균·p95·p99 응답시간, HTTP 5xx 비율
- Tomcat busy/max 스레드
- Hikari active/max, pending, 연결 획득 평균·p95 대기시간, 최근 5분 timeout 증가량
- JVM heap pool 사용량·committed·max, GC pause p95, thread 상태별 개수
- ECS 태스크 CPU·메모리와 Prometheus scrape 상태

`/actuator` 요청은 API 경로별 애플리케이션 트래픽 분석에서 제외한다. 요청 histogram은 애플리케이션 계측 구간을 나타내며 ALB 응답시간과 다를 수 있다. Hikari 연결 획득 대기시간은 SQL 실행시간과 별도 지표다.

## 수집 경로

1. BE의 Spring/Micrometer HTTP·Hikari histogram과 Java agent JVM 메트릭을 노출한다.
2. ECS Alloy 허용 목록을 통해 `backend-metrics` 작업을 Prometheus가 스크랩한다.
3. Java agent는 OTLP HTTP로 Tempo에 trace를 보낸다. 운영 trace sampling 비율은 10%다.
4. Prometheus는 메트릭 수집을 담당하며 OTEL metrics/logs exporter는 비활성화되어 있다.

운영 dashboard 파일은 telemetry EC2 `i-018b437837e804b2d`에 SSM으로 반영했다. 기존 `backend.json`은 `/opt/stockspoon-backend-dashboard-backup.4Vk3Hm`에 백업했다. Grafana API에서 UID, 18개 패널과 URI·Hikari·JVM 패널을 확인했다.

## 2026-11-03 확인 결과

- ECS의 BE 태스크 3개가 실행 중이고 Prometheus `backend-metrics` 타깃 3개가 모두 `up=1`이었다.
- Grafana 패널에 사용되는 라벨 조건으로 시계열이 반환됐다.
  - URI HTTP histogram: 138 series
  - Hikari acquire histogram: 207 series
  - Hikari timeout counter: 3 series
  - JVM GC pause histogram: 414 series
  - JVM heap used: 9 series
  - JVM thread state: 18 series
- 위 숫자는 조회 시점의 시계열 개수다. 특히 `Hikari timeout counter: 3 series`는 timeout 3회 발생을 뜻하지 않는다. 실제 발생량은 대시보드의 최근 5분 counter 증가량으로 확인한다.
- Tempo 최근 24시간 검색은 최대 50개 결과를 반환했고, 조회한 trace에서 23개에 DB/JDBC 형태 span이 있었다. 그중 5개에서 HTTP server span의 직접 자식 DB span을 확인했다. 검색 결과는 전체 trace 개수가 아니라 조회 한도 내 표본이다.

## 브랜치 및 배포 주의 사항

이 문서는 `feat/267-v2-DB-replication` 브랜치에만 추가한다. main 병합이나 PR 생성은 하지 않는다.

이 브랜치는 운영 대시보드 변경을 포함한 Cloud PR #294의 merge commit을 포함하지 않는다. 이 브랜치의 `monitoring/config/grafana/dashboards/prod/backend.json`은 13개 패널인 이전 버전이고, 운영 Grafana에는 PR #294에서 반영한 18개 패널 버전이 올라가 있다. 따라서 이 브랜치의 파일을 SSM으로 다시 배포하면 운영 대시보드가 이전 버전으로 되돌아갈 수 있다. 운영 dashboard 배포의 기준 파일은 PR #294가 병합된 main의 파일이다.

이번 문서 추가 작업에서는 Terraform apply를 실행하지 않았으며, 기존 브랜치 변경 파일을 스테이징하거나 수정하지 않는다.

## 추가 개선 후보

1. **애플리케이션 알림 기준**: HTTP p95·5xx, Hikari pending·timeout, heap 압박, GC pause에 서비스별 임계치와 알림 수신 경로를 정한다. 대시보드 패널만으로는 장애 알림이 보장되지 않는다.
2. **Grafana에서 Tempo로 이동**: 느린 URI 패널에서 exemplar 또는 trace ID를 통해 같은 요청의 Tempo trace로 바로 이동할 수 있도록 연결을 검토한다. 현재 trace와 JDBC span은 수집되지만 패널에서의 직접 이동은 별도 확인이 필요하다.
3. **스레드 경합 원인 분석**: thread 상태 패널은 상태별 개수만 보여준다. 잠금 경합 위치를 찾으려면 부하 구간의 JFR 프로파일을 수집하고 보관하는 절차가 필요하다.
4. **SQL digest 분석**: 이 BE 대시보드는 요청·풀·JVM 지표와 trace span을 보여주지만 PMM Query Analytics의 normalized SQL digest, 상위 SQL, 실행 통계 분석을 대체하지 않는다. slow SQL 집계가 필요하면 PMM QAN 수집 상태와 데이터 보존 정책을 별도로 운영해야 한다.
5. **성능 기준선**: 정상 부하와 피크 부하의 URI별 p95/p99, Hikari 대기, GC, CPU·메모리를 저장해 회귀 비교 기준을 만든다.

## 참고

- Cloud dashboard 변경: [PR #294](https://github.com/100-hours-a-week/KTB4-11th-Cloud/pull/294)
- BE 운영 태스크 설정 보완: [PR #237](https://github.com/100-hours-a-week/KTB4-11th-BE/pull/237), [PR #238](https://github.com/100-hours-a-week/KTB4-11th-BE/pull/238)
- 운영 대시보드 UID: `stockspoon-prod-backend`
