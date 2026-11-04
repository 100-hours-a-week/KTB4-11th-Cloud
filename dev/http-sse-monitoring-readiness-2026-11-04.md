# HTTP·DB·SSE 부하 실험 모니터링 점검

점검일: 2026-11-04 KST. 사용자가 지정한 Grafana 대시보드 네 개의 실제 화면, 저장소 패널 쿼리와 기존 BE 관측 적용 기록을 확인했다. 아래 대시보드·k6 보완은 저장소에 반영했지만, 운영 Grafana 배포와 부하 실행은 수행하지 않았다. 현재 화면의 값은 시험 결과가 아닌 점검 당시 운영 상태다.

## 판단

- HTTP 정상군+요청 증가 및 API 비용 후보 선정은 기존 HTTP Flood·BE·DB 대시보드로 시작할 수 있다.
- 첫 HTTP 429 시각과 URI별 응답 본문 크기는 k6 로그·summary에 보완했다. 최초 차단 여부는 WAF 원본 로그와 함께 확인한다.
- DB 전체 QPS와 API 전체 응답시간은 URI별 SQL 횟수·SQL 실행시간을 직접 제공하지 않는다. 기존 Tempo/JDBC 수집을 활용할 수 있는지 먼저 확인한다. 새 tracing 도입이 무조건 필요한 상태로 판단하지 않는다.
- SSE 연결 점유·큐·자원 회수는 기존 FIS 대시보드를 중심으로 측정 가능하다. 기본 시세 대시보드와 클라이언트 수신 측정을 함께 사용한다.

## HTTP Flood 대시보드

대시보드 UID: stockspoon-http-flood. 사용자가 지정한 2026-11-03 20:32–20:40 KST 구간을 열고 패널 구성을 확인했다.

확인한 구성:

- WAF CountedRequests/BlockedRequests: Sum, period=60초.
- CloudFront 전체 배포 요청·4xx/5xx, ALB 특정 Target Group 요청·오류·p50/p95/p99.
- Spring route별 요청률·p95, 앱 429/5xx, 요청 감사 로그.
- Tomcat, Hikari active/max/pending, Task CPU·Working Set.
- 요청별 WAF 로그는 aws-waf-logs-stockspoon-api-rate-limit, us-east-1에서 조회한다는 안내가 있다. 안내에는 Grafana의 Logs Insights 권한 제한도 적혀 있다. 이번에는 해당 IAM 권한을 직접 재검증하지 않았다.
- WAF 안내 패널은 시험 출발지 IP로 좁혀 가장 이른 rate-rule 이벤트를 찾도록 보완했다. WAF 그래프의 1분 단위 시계열을 초 단위 최초 차단 시각으로 해석하지 않도록 설명을 추가했다.
- `rate-limit.js`는 각 VU가 처음 관측한 HTTP 429의 UTC 시각과 정규화된 URI를 로그에 남기고, scenario·URI별 응답 본문 바이트 및 존재하는 경우 Content-Length를 k6 summary에 기록하도록 보완했다.

판정:

- 분당 차단 건수와 오리진 유입 변화: 기존 구성으로 가능.
- 요청 증가 시작부터 첫 차단까지의 관측 시간: 그래프만으로 초 단위 산출 불가. k6의 증가군 시작 이벤트·각 429 관측 시각과, WAF 로그의 timestamp/clientIp/uri/action/terminatingRuleId를 대조한다.
- 최초 차단 시각에서 시험 시작을 뺀 값은 '차단이 처음 관측되기까지 걸린 시간'이다. AWS 내부 판단·전파 지연만을 분리한 값은 아니다. 이전 요청 이력과 집계 조건을 함께 기록한다.
- 정상군과 증가군이 같은 URI를 사용하면 Spring route 지표에는 합쳐진다. 각 군의 사용자 경험은 k6에서 별도 측정한다.
- ALB Target Group이 저장소에서 특정 green ARN으로 고정되어 있으므로 실행 전 실제 활성 Target Group과 일치하는지 확인한다. 이 점검에서는 실제 ALB 라우팅 상태를 조회하지 않았다.

## BE 대시보드

대시보드 UID: stockspoon-prod-backend. 실제 화면에 18개 패널이 있고 URI 시계열과 Task별 자원이 반환된다.

확인한 지표:

- URI·Task별 요청률, 평균·p95·p99 앱 응답시간, 5xx 비율.
- Tomcat 사용 스레드, Hikari active/max·pending.
- DB 연결 획득 평균·p95 대기시간과 최근 5분 timeout 증가량.
- Task CPU·Working Set, JVM heap·GC pause·thread 상태, scrape up.

실제 그래프에서 세 Task의 scrape up=1, Hikari 평균 획득 대기와 p95 곡선, Task CPU·메모리 시계열을 확인했다. 값의 정밀한 원본 내보내기나 모든 패널의 전체 표본 수집은 이번 범위가 아니다.

해석 한계:

- Hikari 획득 대기는 애플리케이션이 DB 연결을 빌리는 시간이며 SQL 실행시간이 아니다.
- histogram p95는 bucket에서 계산한 추정치다. 이번 화면의 Hikari p95 약 1ms 부근을 그보다 훨씬 짧은 평균 대기와 직접 비교해 실제 tail 지연을 단정하지 않는다. bucket 경계를 확인해야 한다.
- 응답 크기 패널은 확인되지 않았다. k6에서 URI별 응답 body 바이트를 별도 기록한다. JS 문자열 length를 바이트 수로 사용하지 않으며, 논리 body 크기와 압축된 전송량을 구분한다. 응답 원문은 저장할 필요가 없다.
- 현재 URI 지표는 군별·계정별 지표가 아니다. 정상군/증가군 분리는 클라이언트에서 한다.
- URI별 응답 크기는 Grafana 서버 지표가 아니라 k6 summary에서 정상군·증가군별로 비교한다. 본문 크기와 Content-Length는 전체 TLS/TCP wire bytes와 같지 않다.

## DB 대시보드

대시보드 UID: stockspoon-mysql-replication, 별도 Grafana https://3.35.13.60.

실제 값이 반환되는 항목:

- Primary/Replica 접속 상태·read_only, 연결 수·처리 중 스레드.
- DB 전체 QPS, slow queries/s, InnoDB 물리 읽기 비율.
- native·heartbeat 복제 지연·복제 오류.
- ProxySQL backend ONLINE, used/free 연결, backend ping, backend로 보낸 쿼리/s, client 연결·pool 획득 실패.
- 저장소의 DB 대시보드 JSON에 DB 호스트 CPU 사용률·I/O wait, 메모리 사용률, 루트 파일시스템 사용률을 추가했다. 기존 Prometheus `node` job에서 수집하는 시계열을 재사용하며 새 exporter는 추가하지 않았다. 운영 화면 반영은 아직 안 됐다.

느린 SQL 원문 패널은 Inspect Query에서 Loki `{host=~".*", job="mysql-slow"}` 조회가 0행인 것을 확인했다. 이는 해당 조회 구간에 반환된 로그가 없다는 사실이며, 수집 파이프라인 정상 여부나 모든 SQL이 빠르다는 증거는 아니다. slow query 기준(long_query_time 등)과 파일→Loki 수집 상태는 별도 확인 대상이다.

해석 한계:

- QPS는 DB 전체 집계이고 모니터링·백그라운드·다른 사용자 쿼리가 포함될 수 있다. QPS를 시험 API RPS로 나누어 정확한 요청당 SQL 수로 결론내리지 않는다.
- ProxySQL backend ping은 SQL 실행시간이 아니다.
- 현재 대시보드에서 URI별 SQL 횟수·시간, SQL digest 상위 비용은 확인되지 않았다.
- DB 호스트 CPU·메모리·루트 디스크 사용률은 저장소 대시보드에 추가했다. 디스크 I/O 지연과 MySQL row lock 대기는 확인된 수집 시계열에 없어 아직 추가하지 않았다. DB 병목이 의심될 때 실제 exporter 수집 여부부터 확인한다.

## 기존 Trace의 활용 범위

monitoring/BE_BACKEND_OBSERVABILITY.md에는 2026-11-03 Tempo와 JDBC span 연결 확인 및 trace sampling 10%가 기록돼 있다. 이는 과거 적용 확인 기록이다.

이번 점검에서 운영 도메인의 Explore를 통해 backend trace를 조회하려 했으나 홈으로 리다이렉트되어 실제 trace를 열지 못했다. 현재 접근 세션의 이유는 확정하지 않았고, 현시점 수집 성공을 독립적으로 확인하지 못했다.

다음 SQL 원인 분석 단계에서는 기존 Tempo를 조회할 수 있는 세션으로 시험 시간·URI의 HTTP trace와 JDBC span을 연결한다. 표본 trace는 SQL 실행 형태·시간·중복 호출의 단서를 제공하지만, sampling된 표본 수를 전체 SQL 횟수로 사용하지 않는다. exact count가 필요하면 수집 범위가 명확한 별도 계측·SQL digest 근거가 필요하다.

## SSE 대시보드

사용자 지정 UID stockspoon-market-fis의 실제 화면과 패널 쿼리를 확인했다.

재사용 가능한 항목:

- Task scrape 상태, SSE 활성 연결.
- Pub/Sub 수신 메시지·payload bytes/s, 실시간 SSE 전송 이벤트/s.
- 구독자 큐 수·적체 이벤트·payload 메모리·현재 최대 길이·high watermark.
- 큐 포화·discard·느린 구독자 종료.
- send in-flight·pending delivery marker·전송 바이트·framing buffer.
- 프로세스 RSS·CPU·서버측 전달 지연 p95, 구독 복구 로그.

점검 화면에서는 두 Task up=1, SSE 활성 연결·실시간 전송·현재 큐는 0, RSS·CPU와 Pub/Sub 수신량은 실제 값이 반환됐다. 연결이 없는 현재 상태에서 전달 지연 표본이 없을 수 있으므로 시험 전 정상 구독 시 해당 지표가 발생하는지 확인한다.

test-streamer의 up은 0, 발행량·발행 지연 등은 No data였다. 발행기를 정지해 둔 것인지 실제 장애인지는 이번에 확인하지 않았다. 실시간 원본을 이용하는 시험이면 해당 test-streamer 패널이 필수는 아니며, 합성 발행기를 이용하는 시험이면 발행기 수집·출력을 먼저 확인한다.

기본 시세 대시보드 stockspoon-ecs-sse의 저장소 쿼리에는 연결 시작·종료율, SSE 전송 bytes/s, Valkey 연결 풀·획득 대기·timeout, 원본 시세 age·수신량, Task 수·컨테이너 자원이 있다. FIS 화면의 '기본 시세 서버 대시보드' 링크로 함께 사용할 수 있다. 이 추가 대시보드는 이번에 실제 화면 전체를 열람하지 않았다.

이번 보완으로 저장소의 market-FIS 대시보드에도 연결 시작·종료율과 SSE 전송 bytes/s를 추가하고 전달 지연을 p95/p99로 표시하도록 했다. 이미 Prometheus에서 수집 중인 지표를 재사용하며 새 exporter는 추가하지 않았다. 변경된 대시보드 JSON은 배포 전 상태다.

한계와 보완:

- market-fis의 발행 payload·Pub/Sub 수신 bytes는 클라이언트로 전달된 전체 응답 bytes와 다르다. 송신 비용은 기본 시세 대시보드의 SSE 전송 bytes도 함께 본다.
- 서버측 ASGI 전달 지연은 클라이언트 수신 지연·화면 갱신 완료와 다르다. 기존 `fis/market-http/client/sse.js`는 그룹·클라이언트·시각이 포함된 `FIS_EVENT`와 최초 유효 데이터, 데이터 최신성, 재연결·회복 지표를 기록한다. 시험 결과에서는 서버 그래프와 이 클라이언트 기록을 함께 본다.
- server Task·stream별 집계는 정상군을 직접 구분하지 않는다.
- FD는 확인된 FIS 패널에 없다. FD 고갈까지 원인을 규명하려는 단계에서 기존 process 지표 노출 여부를 확인한다. 최초 큐·메모리 회수 시험을 위해 반드시 새 FD 수집부터 배포해야 하는 것은 아니다.
- high watermark는 누적 최고치이므로 종료 후 0이 되어야 하는 자원으로 판정하지 않는다. 현재 연결·큐·pending 자원의 회수를 확인한다.

## 남은 실험 준비 항목

1. HTTP 정상군과 증가군을 동시 실행할 때 각 발생기의 egress IP·요청량·지연·오류를 UTC 단계별로 기록한다. 앱 Grafana의 URI 지표는 두 군을 분리하지 않는다.
2. k6에서 가장 이른 `first_http_429_by_vu` 시각과 WAF 로그의 출발지 IP·rule·action을 대조한다.
3. SSE `FIS_EVENT`/summary에서 정상군을 분리하고 계획된 종료와 전송 오류를 구분해 결과를 집계한다.
4. 실행 전 Prometheus `up`, 실제 활성 ALB Target Group, WAF 모드, 시험 시간 범위를 확인한다. Grafana refresh 간격을 Prometheus scrape 해상도로 오해하지 않는다.

이 항목을 보완하면서 기존 대시보드를 활용한다. 기본 실험을 시작하기 위해 모든 SQL 분석·FD·프로파일링 기능을 먼저 새로 구축할 필요는 없다. SQL 원인 단정·정확한 요청당 SQL 수 등의 결론은 근거 수집 수준에 맞춰 제한한다.

## 근거 파일·문서

- monitoring/config/grafana/dashboards/prod/http-flood.json
- monitoring/config/grafana/dashboards/prod/backend.json
- monitoring/config/grafana/dashboards/prod/market-fis.json
- monitoring/config/grafana/dashboards/prod/ecs-sse.json
- loadtest/waf/rate-limit.js, loadtest/waf/README.md
- fis/market-http/client/sse.js
- app-server/db-migration/plg/server/grafana/provisioning/dashboards/mysql/replication.json
- app-server/db-migration/plg/server/prometheus.yml.tmpl
- monitoring/BE_BACKEND_OBSERVABILITY.md
- [AWS WAF metrics](https://docs.aws.amazon.com/waf/latest/developerguide/waf-metrics.html): 1분 단위 보고.
- [Prometheus histogram](https://prometheus.io/docs/practices/histograms/): histogram 분위수 해석.
