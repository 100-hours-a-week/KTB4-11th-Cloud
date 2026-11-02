# PMM·PLG·BE 대시보드 현재 구성

검토 기준일: 2026-11-02  
범위: `i-00dce75378431daf7`의 PMM/DB 마이그레이션 PLG와 별도 V2 BE 관측 스택  
상태: 저장소 설정과 기록을 정리한 문서다. AWS 인스턴스와 Grafana의 현재 실시간 상태는 캡처로 확인해야 한다.

## 요약

현재 구성은 세 부분으로 나뉜다.

| 구성 | 역할 | 코드/문서상 범위 |
| --- | --- | --- |
| PMM | DB 쿼리 통계와 DB 상태 | MySQL QAN은 MySQL 서비스 등록 및 수집 설정이 필요하다. 운영 메모의 마지막 확인에는 PMM 자체 PostgreSQL만 등록되어 있고 MySQL은 등록되지 않은 것으로 적혀 있다. |
| DB 마이그레이션 PLG | Primary·Replica, ProxySQL, DB 호스트와 로그 | PMM과 같은 EC2를 사용한다. 운영 메모는 두 스택을 동시 운영하지 않고 PLG 실행 시 PMM 컨테이너를 중지한다고 설명한다. |
| V2 PLG/Tempo | ECS Backend 애플리케이션 메트릭과 트레이스 | 별도 관측 스택이다. V2 Backend 대시보드에 HikariCP와 HTTP 성능 패널이 이미 정의되어 있으며, 2026-10-29 시간대의 과거 Grafana 캡처에 데이터가 표시되어 있다. |

이 문서에서 “설정됨”은 저장소 코드에 정의되어 있다는 뜻이다. Terraform 예시 변수 파일과 과거 캡처만으로 현재 AWS에 적용된 상태라고 단정하지 않는다.

## 1. PMM 및 DB 마이그레이션 PLG

### PMM

- 대상 EC2: `i-00dce75378431daf7`
- PMM Compose 이미지: `percona/pmm-server:3.9.1`
- PMM 보관 기간 설정: 72시간
- 메트릭 해상도 설정: 5초 기본, 추가 단계 10·30·60초
- PMM 컨테이너 메모리 제한: 3200 MiB
- 데이터는 `pmm-data` Docker volume에 보관한다.
- 코드: [`pmm-compose.yaml`](../app-server/db-migration/pmm-compose.yaml)

PMM Query Analytics(QAN)는 DB 쿼리 유형별 집계와 쿼리 지문을 분석하는 기능이다. BE의 Hikari 연결 대기시간이나 HTTP 요청 지연 지표를 대신하지 않는다. MySQL 쿼리 데이터가 필요하면 실제 서비스 쿼리를 받는 MySQL 서비스를 PMM에 등록해야 한다. 운영 메모는 PMM 자체 PostgreSQL만 등록되고 V1·이관 MySQL은 미등록이라고 기록한다. 또한 2026-11-02 대상 변경은 Terraform 및 호스트 배포 전이라고 적혀 있어, 현재 PMM Inventory 화면 확인이 필요하다.

- 운영 기록: [`OPERATIONS.md`](../app-server/db-migration/OPERATIONS.md)
- QAN 설정 스크립트: [`configure_pmm_mysql.sh`](../app-server/db-migration/configure_pmm_mysql.sh)

### DB 마이그레이션 PLG

PLG는 위 PMM과 같은 EC2에서 실행하는 별도 Compose 스택이다. 운영 메모에 따르면 인스턴스 메모리 여유를 위해 PMM과 PLG를 동시에 실행하지 않는다. PLG Compose는 Loki, Prometheus, Grafana, MySQL exporter, Alertmanager, heartbeat writer를 정의한다.

- Prometheus 스크랩 주기: 5초
- Prometheus 보관 설정: 72시간 또는 8GB
- Prometheus/Grafana 관리 포트: 호스트 loopback에 바인딩
- 코드: [`compose.yaml`](../app-server/db-migration/plg/server/compose.yaml), [`prometheus.yml.tmpl`](../app-server/db-migration/plg/server/prometheus.yml.tmpl)
- DB 알림: [`db-alerts.yml`](../app-server/db-migration/plg/server/prometheus-rules/db-alerts.yml)

현재 설정에 정의된 수집 대상은 Primary·Private Replica의 MySQL, 두 DB 호스트의 node exporter, ProxySQL Fargate다. 로그 수집 경로는 Alloy를 통해 Docker 로그와 설정된 MySQL `general.log`/`slow.log` 파일을 Loki로 보낸다.

### MySQL · Primary & Replica 대시보드

현재 저장소의 JSON에는 21개 패널이 정의되어 있다. 크게 DB 상태·복제·쿼리 부하·ProxySQL로 구성된다.

- DB 상태: MySQL 연결, read-only 상태, 연결 수, 처리 중 스레드
- 복제: I/O·SQL 수신/적용 상태, native lag, 오류 번호, heartbeat 지연
- 부하: QPS, 연결 수 추이, slow query/s, InnoDB buffer pool 물리 읽기 비율
- ProxySQL: 상태, backend 연결 수, ping 지연, 쿼리/s, 클라이언트 연결 및 pool 획득 실패

대시보드 파일: [`replication.json`](../app-server/db-migration/plg/server/grafana/provisioning/dashboards/mysql/replication.json)

운영 메모의 2026-10-26 검증 기록은 12개 패널·13개 쿼리를 언급하지만, 현재 체크아웃의 대시보드 JSON은 21개 패널이다. 검증 시점 이후 패널이 추가된 것으로 보이며, 화면 캡처로 실제 배포본을 대조해야 한다. 같은 문서에 Alertmanager 미구성으로 읽히는 오래된 주석도 있으나 현재 Compose에는 Alertmanager가 있고 Prometheus DB 규칙도 정의되어 있다. Grafana/Prometheus의 실제 알림 상태를 별도로 확인한다.

## 2. V2 ECS Backend 메트릭

V2 Backend용 메트릭은 DB 마이그레이션 PLG가 아닌 별도 V2 PLG/Tempo 스택으로 수집하도록 구성되어 있다.

1. ECS 호스트의 Alloy가 ECS Backend 태스크를 발견한다.
2. Backend의 `/actuator/prometheus`를 15초 간격으로 스크랩한다.
3. Prometheus remote write로 V2 관측 서버에 전송한다.
4. Grafana 대시보드 `ECS BE 모니터링`에서 태스크 단위로 본다.

관련 파일:

- Actuator 환경 변수와 필수 라이브러리 주석: [`svc_backend.tf`](../ecs/svc_backend.tf)
- ECS 호스트 → Backend 태스크 보안그룹과 공개 ALB 차단 규칙: [`backend_metrics.tf`](../ecs/backend_metrics.tf)
- ECS 태스크 발견, `/actuator/prometheus` 스크랩과 메트릭 필터: [`config.alloy`](../ecs/alloy/config.alloy)
- 운영 예시 feature flags: [`ecs prod terraform.tfvars.example`](../ecs/environments/prod/terraform.tfvars.example)
- Grafana 대시보드: [`backend.json`](../monitoring/config/grafana/dashboards/prod/backend.json)

`telemetry_backend_prometheus_enabled`와 `plg_tempo_enabled`는 운영 예시에서 `true`지만, 예시 파일은 실제 Terraform 적용 상태의 증거가 아니다. Backend 이미지에는 `micrometer-registry-prometheus`가 있어야 하며, Terraform 설정만으로 라이브러리를 추가하지 않는다. Actuator 경로는 호스트 Alloy에서 접근하도록 제한하고 공개 ALB에는 404 차단 규칙을 둔다.

### V2 BE 대시보드 패널

저장소 작업본에는 18개 패널이 정의되어 있다. 이번 변경은 저장소의 Terraform/Alloy/Grafana 구성에만 반영했으며, Terraform plan/apply, Grafana 반영, 서비스 배포는 하지 않았다. 따라서 현재 운영 화면은 기존 캡처와 다를 수 있고, 추가 패널의 데이터 유무는 배포 후 확인해야 한다.

| 구분 | 패널 |
| --- | --- |
| 요청·응답 | URI 템플릿·태스크별 요청량, 평균 앱 응답시간, p95, p99, 5xx 비율. `/actuator` 경로는 제외 |
| 처리 용량 | Tomcat busy/max 비율, busy threads |
| DB 커넥션 풀 | Hikari active/max, pending, DB 연결 획득 평균·p95 대기시간, 최근 5분 timeout 증가량 |
| JVM | heap pool별 used/committed/max 메모리, GC pause p95, 상태별 스레드 수 |
| 건전성·리소스 | 메트릭 수집 상태, 태스크 CPU, 컨테이너 메모리 Working Set |

HTTP 패널은 URI 템플릿과 태스크별로 집계하고, 풀/JVM/리소스 패널은 해당 지표의 의미에 맞게 pool·memory id·thread state 또는 태스크 단위로 집계한다. Alloy 허용 목록과 Spring Boot 분포 설정도 함께 확장해 Hikari acquire histogram과 JVM 지표를 전달하도록 구성했다. 2026-10-29 구간을 보여주는 기존 캡처에는 응답시간, `up=1`, Hikari 연결 획득 평균 대기시간이 표시되어 있다. 이 캡처는 당시 데이터가 있었음을 보여주지만 현재 수집 상태까지 보증하지는 않는다.

- Grafana: [ECS BE 모니터링](https://monitoring.stock-spoon.com/d/stockspoon-prod-backend)
- 기존 캡처: [`03-ecs-be-full`](../app-server/db-migration/runs/collection-20261029T132937Z/grafana-metrics/03-ecs-be-full-20261030T194543.png)

## 3. 대시보드 외 관측 경로

- V2 Backend의 OTLP trace 환경 변수와 Tempo endpoint가 Terraform에 정의되어 있다: [`ecs/monitoring.tf`](../ecs/monitoring.tf)
- Java agent를 앱 이미지에 포함하는 Dockerfile이 있다: [`java.Dockerfile`](../monitoring/instrumentation/java.Dockerfile)
- [`prepare-tracing.py`](../monitoring/scripts/prepare-tracing.py)는 실행 중인 Backend 이미지에 Java agent를 포함하는 빌드·배포 입력을 준비할 수 있다. 생성된 스크립트는 여기서 실행하지 않았다.
- 해당 이미지가 현재 운영 Backend에 배포되어 있고 HTTP server span 아래 JDBC client span이 실제 전송되는지는 Tempo 화면과 태스크 이미지로 확인해야 한다. OTLP 환경 변수만으로는 Java 계측이 활성화되지 않는다.
- DB 마이그레이션 PLG의 DB/ProxySQL 알림은 [`db-alerts.yml`](../app-server/db-migration/plg/server/prometheus-rules/db-alerts.yml)에 있다.
- 저장소의 V2 Grafana 알림 파일에서는 Hikari 전용 알림 규칙을 찾지 못했다: [`rules.json`](../monitoring/config/grafana/provisioning/alerting/rules.json)

## 4. 현재 구성에서 추가 확인할 항목

이 목록은 화면 캡처 전의 코드 기반 관찰이다. 실제 개선 범위는 라이브 화면과 함께 확정한다.

1. PMM이 현재 실행 중인지, PLG 모드인지 확인한다. 두 Compose 스택은 문서상 같은 EC2에서 동시에 운영하지 않는다.
2. PMM Inventory에서 대상 MySQL 서비스가 등록되어 있는지, QAN 데이터가 생성되는지 확인한다.
3. BE 메트릭이 현재 시각까지 들어오는지, Hikari acquire histogram과 `timeout_total`, JVM 메트릭이 실제 Prometheus에 도착하는지 확인한다. 저장소 필터와 패널을 추가했지만 운영 반영은 아직 확인하지 않았다.
4. URI 템플릿별 p95/p99·5xx 패널이 배포 후 데이터와 함께 표시되는지, 고카디널리티 원문 URI 대신 라우트 템플릿을 사용하는지 확인한다.
5. Hikari 평균/p95 대기시간 및 timeout 증가와 DB/ProxySQL 상태를 같은 부하 구간에서 비교한다.
6. JVM heap·GC·thread state 패널을 확인한다. 상태별 스레드 수만으로 잠금 경합 위치를 특정할 수 없으므로, 경합 분석은 부하 구간의 JFR 프로파일이나 trace로 확인한다.
7. V2 Backend trace에서 HTTP 요청과 JDBC span이 연결되는지 확인한다. 기존 준비 스크립트로 instrumented image/task 입력을 만든 뒤 별도 이미지 빌드와 ECS 배포가 필요하다. 로그·쿼리 예시 화면은 업무 값이나 민감한 SQL 값이 노출되지 않도록 한다.

## 5. URL별 캡처 목록

각 화면에서 **제목, 대상/ datasource, 시간 범위**가 보이게 캡처한다. 시간대는 KST로 맞추고, 평상시와 부하가 있었던 구간을 각각 확인한다. PMM과 DB PLG는 같은 EC2에서 교대로 실행되므로, 현재 실행 중인 모드만 캡처하고 캡처를 위해 서비스를 전환하지 않는다.

운영 메모에 기록된 공인 IP는 `3.35.13.60`이다. IP가 바뀌었으면 아래 URL에서 현재 EC2 공인 IP로 바꾼다. PMM과 Grafana는 관리자 IP 허용 목록을 사용하므로 허용된 네트워크에서 접속한다.

### 5.1 PMM

**URL:** <https://3.35.13.60:8443/>

| 순서 | 화면 이동 | 캡처할 내용 |
| --- | --- | --- |
| 1 | Inventory → Services | 등록된 서비스 전체와 agent 상태. Primary/MySQL이 등록되어 있는지 확인한다. |
| 2 | Query Analytics | MySQL 서비스와 시간 범위를 선택한 상위 쿼리 목록. 쿼리 상세에서 호출 수·지연·부하 지표를 캡처하고 원문 파라미터/민감 값은 가린다. |
| 3 | MySQL Instance Summary (선택) | QPS, 접속 수, InnoDB 상태를 함께 볼 필요가 있으면 캡처한다. |

PMM이 실행 중이 아니면 URL 오류 화면 대신 현재 관측 모드를 확인하고, PMM 접속 불가 상태를 기록한다. PMM과 PLG 전환은 캡처 범위에 포함하지 않는다.

### 5.2 DB 마이그레이션 PLG — MySQL 대시보드

**URL:** <https://3.35.13.60/d/stockspoon-mysql-replication>

대시보드 변수를 `DB 노드=All`로 두고 아래 구간을 나눠 캡처한다.

| 캡처 | 패널 범위 | 포함 지표 |
| --- | --- | --- |
| DB PLG 1/3 | 상단, 패널 1–8 | MySQL 연결/read-only, 연결·처리 스레드, 복제 I/O·SQL 상태, native lag, 복제 오류 |
| DB PLG 2/3 | 중간, 패널 9–15 | QPS, 연결 추이, slow query/s, InnoDB buffer pool, heartbeat 지연 |
| DB PLG 3/3 | 하단, 패널 16–21 | ProxySQL 상태, backend 연결, ping, 쿼리/s, 클라이언트 연결 및 pool 획득 실패 |

### 5.3 DB 마이그레이션 PLG — Prometheus 상태

Prometheus `9090` 포트는 공개되지 않고 모니터링 EC2의 loopback에만 바인딩된다. 승인된 SSH 터널 또는 SSM 포트 포워딩을 연 뒤 로컬 브라우저에서 접속한다.

| URL | 화면 | 캡처할 내용 |
| --- | --- | --- |
| <http://localhost:9090/targets> | Targets | `mysql-primary`, `mysql-private-replica`, `node`, `proxysql-fargate` 타깃의 UP/DOWN 상태와 최근 오류 |
| <http://localhost:9090/alerts> | Alerts | MySQL/복제/heartbeat/ProxySQL 규칙의 상태와 firing 여부 |

PLG가 실행 중이 아닐 때는 이 URL이 열리지 않을 수 있다. 이 경우 현재 모드와 Prometheus 화면을 열 수 없다는 점을 기록한다.

### 5.4 V2 Backend Grafana

**URL:** <https://monitoring.stock-spoon.com/d/stockspoon-prod-backend>

대시보드의 Backend task와 API route 변수를 `All`로 두고 다음 다섯 화면을 캡처한다. 저장소 작업본 기준 패널 번호다. 운영 Grafana에 아직 반영되지 않았다면 추가 패널은 보이지 않을 수 있다.

| 캡처 | 패널 범위 | 포함 지표 |
| --- | --- | --- |
| BE 1/5 | 상단, 패널 1–4 | URI 템플릿별 요청량, 평균 앱 응답시간, p95, p99 |
| BE 2/5 | 패널 5–10 | Tomcat busy/max·busy threads, Hikari active/max·pending·평균 획득 대기시간, 수집 `up` |
| BE 3/5 | 패널 14–15 | Hikari 획득 p95 대기시간, 최근 5분 timeout 증가량 |
| BE 4/5 | 패널 11–13 | 태스크 CPU, 컨테이너 메모리 Working Set, URI 템플릿별 HTTP 5xx 비율 |
| BE 5/5 | 하단, 패널 16–18 | JVM heap pool별 used/committed/max, GC pause p95, 상태별 thread count |

### 5.5 V2 Tempo trace

**URL:** <https://monitoring.stock-spoon.com/explore>

Explore에서 Tempo datasource를 선택하고 `backend` 서비스의 대표 요청 trace를 연다. HTTP 요청과 하위 JDBC span이 함께 보이는 waterfall을 캡처한다. trace가 없거나 JDBC span이 없으면 빈 결과 또는 해당 span이 없는 상태를 캡처해 수집 여부를 구분한다.

### 캡처 파일 권장 이름

`01-pmm-services`, `02-pmm-qan`, `03-db-plg-top`, `04-db-plg-workload`, `05-db-plg-proxysql`, `06-prometheus-targets`, `07-prometheus-alerts`, `08-be-http`, `09-be-capacity`, `10-be-hikari`, `11-be-resources`, `12-be-jvm`, `13-tempo-trace`.

캡처 후에는 저장소에 정의된 구성을 실제 화면과 대조해 미배포 설정과 수집 누락을 먼저 구분한다. Terraform 변경이 필요하면 `plan`은 검토용으로만 사용하며, 이 문서 작업에서는 `apply`를 수행하지 않는다.

## 6. 배포 순서

이 순서는 현재 작업본을 운영에 반영할 때의 경로다. Cloud Terraform, Backend 이미지/CD, Grafana dashboard 파일은 서로 다른 배포 소유권을 따른다.

### 6.1 Cloud 저장소 PR과 Terraform

1. 이 브랜치에서 모니터링 변경 파일만 PR에 포함한다: `ecs/svc_backend.tf`, `ecs/alloy/config.alloy`, `monitoring/config/grafana/dashboards/prod/backend.json`, `monitoring/scripts/prepare-backend-metrics-task.py`, `monitoring/DASHBOARD_INVENTORY.md`.
2. GitHub PR Plan에서 `ecs`와 `monitoring` root 결과를 검토한다. `ecs`에서는 Alloy task definition/service 변경과 Backend task definition 변경을 확인한다. PR Plan만으로는 아무것도 배포되지 않는다.
3. 승인 후 보호된 `main`에 병합하면 Terraform Apply workflow가 적용한다. 로컬 `terraform apply`는 하지 않는다.

`aws_ecs_service.backend`는 `task_definition` 변경을 무시하도록 설정되어 있다. 따라서 Terraform Apply가 Backend task definition 리비전을 등록하더라도 실행 중인 Backend task를 그 리비전으로 교체하지 않는다. Alloy task는 ECS Terraform이 관리하므로 Alloy 설정 변경은 이 Apply에서 반영된다.

### 6.2 Backend CI/CD에 Java agent와 task 설정 연결

Cloud Terraform Apply 후 Backend 저장소의 빌드·배포 경로를 반영한다. 애플리케이션 비즈니스 코드 대신 Backend 최종 이미지와 CD task definition 구성을 업데이트한다.

1. Backend 이미지 빌드에서 [`java.Dockerfile`](../monitoring/instrumentation/java.Dockerfile)과 같은 방식으로 Java agent를 포함한다. 이후 정규 Backend 빌드도 agent가 빠지지 않는지 확인한다.
2. BE CD가 새 task definition을 만들 때 기존 secrets·environment를 보존하고 `telemetry_application_environments.backend`의 OTEL 설정과 `SPRING_APPLICATION_JSON`의 Prometheus/HTTP·Hikari·JVM 설정을 포함하는지 확인한다. 현재 Cloud task definition의 Spring 설정은 `ecs/svc_backend.tf`에 있지만, ECS Service가 그 리비전을 자동으로 채택하지는 않는다. Cloud 저장소의 [`prepare-backend-metrics-task.py`](../monitoring/scripts/prepare-backend-metrics-task.py)는 이 HTTP·Hikari·JVM 설정을 task JSON에 병합하도록 갱신했다. 이 helper를 BE CD에서 사용하지 않는다면 같은 설정 병합을 BE CD 쪽에 구현해야 한다.
3. 운영 ECR 이미지 push 권한과 Backend 배포 Role 권한을 각각 확인한다. Backend 배포 Role은 BE ECS 서비스의 task definition 등록·서비스 갱신·task role 전달을 담당한다. 이미지 push는 별도의 ECR 권한이 필요하다.
4. 새 이미지는 Backend 저장소의 정식 CD workflow로 Backend 서비스에만 배포한다. Cloud 저장소의 [`prepare-tracing.py`](../monitoring/scripts/prepare-tracing.py)가 생성하는 로컬 배포 스크립트는 Backend 외 서비스도 다루므로 운영 배포 경로로 바로 사용하지 않는다.

### 6.3 Backend와 Alloy 수집 확인

BE CD 배포가 안정화된 다음 Grafana dashboard를 배포한다. 먼저 Prometheus/Grafana에서 아래 데이터가 들어오는지 확인한다.

- `up{job="backend-metrics",service_name="backend"}`가 `1`
- `http_server_requests_seconds_bucket`에 `uri` 라벨
- `hikaricp_connections_acquire_seconds_bucket`, `hikaricp_connections_timeout_total`
- `jvm_gc_pause_seconds_bucket`, `jvm_memory_used_bytes`, `jvm_threads_states_threads`

### 6.4 Grafana dashboard를 SSM으로 반영

`monitoring` Terraform Apply는 실행 중인 모니터링 서버의 대시보드 파일을 자동 교체하지 않는다. 렌더링 도구는 SSM 요청 payload를 만들기만 하므로, payload 생성과 SSM 제출을 각각 수행한다.

```bash
python3 monitoring/scripts/render-deploy.py server-dashboards \
  --output /tmp/stockspoon-be-dashboards-ssm.json

: "${AWS_PROFILE:?Set AWS_PROFILE to a profile with telemetry EC2 SSM permission}"
aws --profile "$AWS_PROFILE" --region ap-northeast-2 ssm send-command \
  --cli-input-json file:///tmp/stockspoon-be-dashboards-ssm.json
```

이 AWS 호출 주체에는 telemetry EC2를 대상으로 `ssm:SendCommand` 권한이 필요하다. Terraform plan/apply 권한이 이 권한을 자동으로 포함하지 않는다. Grafana는 provisioned dashboard를 주기적으로 다시 읽으며, 배포 스크립트는 기존 dashboard 디렉터리 백업을 남긴다.

### 6.5 Tempo 확인

Tempo에서 `backend` trace를 열고 HTTP server span 아래 JDBC client span이 있는지 확인한다. 기본 샘플링 비율은 10%이므로 대표 요청이 바로 검색되지 않을 수 있다. 상태별 JVM thread 수는 경합 위치를 보여주지 않으며, 경합 원인 분석에는 부하 구간의 JFR 프로파일이 필요하다.

## 7. 배포 전 확인할 소유권

현재 Cloud 저장소에는 BE 저장소의 `cd-ecs-v2.yaml` 본문이 없다. 따라서 실제 BE workflow가 OTEL·Spring 메트릭 환경을 새 task definition에 병합하는지, 운영 ECR push Role이 agent 포함 이미지 push를 허용하는지는 BE 저장소에서 별도 확인한다. 이 두 항목이 확인되기 전에는 Cloud Terraform Apply만으로 HTTP/JVM/Hikari 지표나 JDBC trace가 운영 Backend에 활성화된다고 간주하지 않는다.
