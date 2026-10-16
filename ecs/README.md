# ECS

운영 ECS 클러스터와 서비스를 관리하는 Terraform root입니다.
V1 EC2에서 실행 중인 Backend를 ECS로 이전하고, 이후 역할별 서비스(Socket, Market Data, Match Engine)를 같은 클러스터에 추가합니다.

## 참조 관계

```
ecs ──참조──> shared-infra      (VPC, Private Subnet)
    ──참조──> app-server        (ALB 리스너, Blue TG, ALB·V1 앱 SG·private IP, Public ECR)
    ──참조──> redis (prod)      (Valkey 엔드포인트, 서비스별 사용자·Connect Policy)
    ──참조──> ai-server/infra   (V1 AI 운영 서버 private IP·SG)
```

- 참조는 `ecs` → 다른 root 방향으로만 합니다. `shared-infra`, `app-server`는 `ecs`를 참조하지 않습니다.
- 다른 root가 소유한 리소스(ALB 리스너, V1 SG)에 규칙을 추가할 때는 그 규칙을 이 root에서 소유합니다.

## 파일 구성

추후 platform과 service를 별도 root로 분리할 수 있도록 레이어별로 파일을 나눕니다.

| 파일 | 내용 |
|---|---|
| `platform_*.tf` | 모든 서비스가 공유하는 리소스 (계정 설정, IAM, Cluster, ASG, Capacity Provider) |
| `svc_<서비스>.tf` | 서비스 전용 리소스 (로그 그룹, Task Role, Target Group, Task Definition, Service) |
| `svc_proxysql.tf` | 단일 AZ ProxySQL ECS 서비스, MySQL 네트워크 검사 |
| `cross_root_rules.tf` | 다른 root 소유 리소스에 추가하는 규칙 (리스너 규칙, SG 규칙) |
| `backend_canary.tf` | Backend API 요청의 V1/V2 가중치 라우팅 |

## 이름 규칙

모든 IAM Role·Instance Profile 이름은 `stockspoon-v2-prod-*`로 시작합니다. (개발 리소스의 `stockspoon-v2-dev-*`와 같은 규칙)
Terraform CI 권한이 이 접두사로 제한되어 있습니다.

## Secret 주입

- 애플리케이션 Secret은 **SSM Parameter Store SecureString**에 저장합니다.
- 경로: `/stockspoon/v2/prod/<서비스>/<이름>` (예: `/stockspoon/v2/prod/backend/DB_PASSWORD`)
- 값은 콘솔이나 CLI로 직접 등록하고, Terraform으로 관리하지 않습니다. (값이 state에 남지 않게 하기 위함)
- Task Execution Role은 `/stockspoon/v2/prod/*` 경로만 읽을 수 있습니다.

```bash
aws ssm put-parameter --type SecureString \
  --name /stockspoon/v2/prod/backend/DB_PASSWORD --value '<값>'
```

## 컨테이너 이미지

이미지 저장소(Private ECR)는 ECS와 수명이 달라 별도 `ecr` root에서 관리합니다.

## 리소스 구성

| 파일 | 리소스 |
|---|---|
| `platform_cluster.tf` | ECS Cluster, Service ASG(Launch Template, 인스턴스 SG), Capacity Provider |
| `svc_backend.tf` | Backend 로그 그룹, Task Role(Valkey `backend`), Task SG, Green Target Group, Task Definition(V1 MySQL 사용), ECS Service |
| `svc_market_common.tf` | market-http 공통 값 (이미지, V1 AI private IP, Valkey 접속 정보) |
| `service_scaling.tf` | 서비스별 Task 2~4개, Backend CPU 60%, SSE 연결 400개/Task, 선택적 예약 확장 |
| `svc_market_http.tf` | market-http(SSE) 로그 그룹, Task Role(Valkey `socket`), Task SG, Target Group, Task Definition, ECS Service |
| `ci_deploy_role.tf` | ECS 배포 Role: 각 앱 레포 `cd-ecs-v2.yaml`. Task Definition 등록, 자기 서비스 갱신, Task Role PassRole |
| `cross_root_rules.tf` | ALB SG → Task egress, HTTPS 리스너 규칙(market-http `/market/*`), V1 AI SG ingress(QuestDB), V1 앱 SG ingress(MySQL) |
| `backend_canary.tf` | 운영 `/api/*` 요청을 V1 Blue/V2 Green에 가중치로 분배하는 선택적 리스너 규칙 |

## 용량 설계

- Backend와 market-http(SSE)는 `c6i.xlarge`(4 vCPU / 8 GiB) ASG와 Capacity Provider 하나를 공유합니다. ASG min / 초기 desired / max는 2 / 2 / 4입니다.
- Task 사양은 Backend 1 vCPU / 2 GiB, market-http 2 vCPU / 4 GiB입니다. 각 EC2에 하나씩 배치하면 3 vCPU / 6 GiB를 예약하며 나머지는 OS·ECS Agent와 추가 Task에 사용합니다.
- Capacity Provider `target_capacity=100`, warmup 300초, 확장 step 최소·최대 1대를 사용합니다. Managed Draining·Termination Protection을 유지합니다.
- 서울 리전 2a·2c의 private subnet을 사용하며, 두 서비스 모두 AZ → 인스턴스 순서로 분산합니다. `spread`는 최선 노력 방식이며 `distinctInstance` 제약은 적용하지 않습니다.
- 평상시 합계 예약은 6 vCPU / 12 GiB, 두 서비스가 각각 4개면 12 vCPU / 24 GiB입니다. 실제 등록 메모리는 EC2 명목 메모리보다 작으므로 최대 Task 구성에 EC2 4대가 필요할 수 있습니다. 배포용 추가 Task에도 여유 용량이 필요합니다. 특히 각 서비스 4개·EC2 4대가 모두 찬 상태에서는 Rolling 100/200 배포가 진행되지 않을 수 있으므로, 배포 전에 ASG 상한·여유 용량 또는 배포 정책을 별도로 조정해야 합니다.

### Task Auto Scaling

| 서비스 | 최소 / 초기 desired / 최대 | 동적 확장 기준 |
|---|---|---|
| Backend | 2 / 2 / 4 | ECS 서비스 평균 CPU 60% |
| market-http (SSE) | 2 / 2 / 4 | Task별 활성 SSE 연결 수의 평균 400개 |

- 확장 cooldown은 60초, 축소 cooldown은 300초입니다. Task 확장 후 EC2가 부족하면 Capacity Provider가 ASG를 확장합니다.
- Terraform은 서비스 `desired_count`를 무시하며, 최초 생성 이후에는 Application Auto Scaling이 관리합니다. 대상 등록 시 최소 2개를 적용하므로 기존 Backend desired 1도 2로 올라갑니다.
- SSE 앱의 순수 ASGI 미들웨어는 `text/event-stream` 응답이 열린 동안 연결을 세고, 종료·취소·전송 실패 시 해제합니다. 가격·호가 스트림을 합산하며 일반 REST·헬스체크는 제외합니다.
- 앱은 Task마다 단일 uvicorn 프로세스로 60초마다 연결 gauge를 EMF JSON으로 stdout에 기록합니다. 유휴 Task도 0을 발행하며 CloudWatch `Average`로 Task 평균을 계산합니다. 다중 worker 전환 시 이 집계 방식을 먼저 변경해야 합니다.
- 지표는 `StockSpoon/ECS`, `ActiveSSEConnections`, `Count`, dimensions `ClusterName` / `ServiceName`입니다. 기존 awslogs 경로를 사용하므로 `cloudwatch:PutMetricData` 추가 권한은 필요 없습니다.
- 앱 배포 템플릿에 `MARKET_HTTP_METRICS_NAMESPACE`, `MARKET_HTTP_METRICS_CLUSTER_NAME`, `MARKET_HTTP_METRICS_SERVICE_NAME`을 지정해야 합니다. 기존 이미지에는 계측 코드가 없으므로 AI 앱 코드의 CI·배포가 필요합니다. 지표가 없으면 SSE 동적 확장은 동작하지 않습니다.
- 400개와 Task 사양은 기존 WebSocket 설계의 초기값입니다. SSE 연결 수는 사용자 수나 구독 종목 수가 아니며, 현재의 이벤트 전송량·지연·메모리·재연결을 부하 테스트로 검증해야 합니다.
- SSE 종료 정책은 현재 운영 설정인 ALB drain 30초 / stopTimeout 30초를 유지합니다. 브라우저 재연결 후 최신 snapshot을 받는 동작을 검증합니다. 원문 WebSocket의 drain 120초는 자동으로 이식하지 않습니다.

### 개장 전 선확장

- Backend와 SSE(market-http) 모두 평일 08:40(Asia/Seoul)에 최소 3개로 선확장하고, 15:40에 최소치를 2개로 복귀합니다. 최대치는 항상 4개입니다.
- `service_preopen_scaling` 기본값에 두 서비스의 시작·복귀 예약이 포함됩니다. Terraform apply 시 서비스별 2개씩 총 4개의 예약 작업이 생성됩니다. `{}`로 재정의하면 예약을 비활성화할 수 있습니다.
- 서비스 키 `backend` 또는 `market-http`에 `min_capacity`, `preopen_schedule`, `restore_schedule`을 지정합니다. 기본 시작 cron은 `cron(40 8 ? * MON-FRI *)`, 복귀 cron은 `cron(40 15 ? * MON-FRI *)`입니다.
- 복귀 예약은 최소치만 2로 낮추고 최대 4는 유지합니다. 실행 중 Task를 즉시 2개로 강제하지 않고 동적 정책으로 축소합니다.
- 예약이 변경한 `min_capacity`는 Terraform이 무시합니다. 예약 삭제 시에는 런타임 최소치가 자동으로 2로 돌아오지 않으므로 Application Auto Scaling에서 최소 2를 명시적으로 복원합니다.
- 평일 cron에는 한국 증시 휴장일이 자동 반영되지 않습니다.

### 적용 순서

1. `app-server`의 Terraform CI IAM 정책을 먼저 반영합니다. ECS 서비스 Auto Scaling API와 서비스 연결 역할 생성 권한이 추가됩니다.
2. BE `.aws/ecs/backend.json`(1 vCPU / 2 GiB), AI `.aws/ecs/market-http.json`(2 vCPU / 4 GiB, 계측 환경변수)과 AI SSE 계측 코드를 각 앱 CI·CD로 배포합니다. BE·AI 간 순서는 무관합니다.
3. 실제 Task Definition 사양과 SSE 지표의 유휴 0·연결 증가·해제를 확인합니다.
4. 이 root의 plan을 검토하고 apply합니다. Task 실행 사양은 앱 템플릿과 CD 소유이므로 Terraform apply만으로 변경되지 않습니다.
5. 서비스별 Task 확장 범위 2~4개, Target Tracking 알람과 08:40 선확장·15:40 최소치 복귀 예약을 확인합니다. 장중 예약이 실행된 뒤에는 최소치가 3개입니다.

로컬 AWS 명령과 Terraform은 `AWS_PROFILE=pattie_for_terraform`을 사용합니다.

## 경로 라우팅

| 경로 | 대상 | 비고 |
|---|---|---|
| `/api/*` | V1 Blue / V2 Green 가중치 분배 | Canary 활성화 시 우선 적용. 초기 V1 100% / V2 0%, 헤더 조건 없음 |
| `/market/*` | ECS market-http | ALB가 `/market` 접두사를 제거해 전달 (`/market/prices` → `/prices`). V1에 없는 경로라 헤더 없이 바로 운영 |
| 그 외 | V1 EC2 (기본 action) | |

```bash
# Backend는 현재 가중치를 따른다. 기본값은 V1 100% / V2 0%.
curl -s https://stock-spoon.com/api/v1/auth/csrf

# market-http
curl -s 'https://stock-spoon.com/market/prices?codes=005930'
curl -sN 'https://stock-spoon.com/market/prices/stream?codes=005930'   # SSE
curl -s 'https://stock-spoon.com/market/bars/005930?timeframe=1d&limit=5'
```

### Backend 운영 트래픽 전환

`backend_canary_enabled=true`가 기본값이다. 기존 priority 100 헤더 규칙의 Terraform 주소를 `moved` 선언으로 가중치 규칙에 인계하고, 같은 AWS 규칙에서 헤더 조건을 제거해 가중치 전달로 수정한다. 같은 우선순위로 새 규칙을 생성하다 충돌하는 상황을 피하며 리스너 규칙 ARN은 유지한다. 규칙은 `/api/*`의 모든 HTTP 메서드에 적용되며 헤더에 따라 V2로 직행하는 경로는 남기지 않는다. `/market/*`와 프런트엔드 기본 경로는 유지한다.

| 변수 | 초기값 | 의미 |
|---|---|---|
| `backend_canary_enabled` | `true` | `false`로 apply하면 가중치 규칙을 삭제하고 V1 기본 경로로 복귀 |
| `backend_canary_green_weight` | `0` | V2 비중(0~100 정수). V1 비중은 `100 - V2` |
| `backend_canary_rule_priority` | `100` | HTTPS 리스너의 규칙 우선순위 번호 |

V1 Blue는 EC2의 Nginx HTTPS:443으로 전달되고, Nginx의 `location /api/`가 내부 `backend:8080`으로 원래 URI를 유지해 프록시한다. V2 Green은 ECS Backend:8080으로 같은 URI를 직접 전달한다. 양쪽 백엔드는 `/api/v1/...`를 제공하므로 `/api` 접두사를 제거하지 않는다.

가중치는 요청을 확률적으로 분배한다. 타깃 그룹 stickiness는 비활성화하며, 로그인한 한 계정의 요청도 양쪽으로 전달될 수 있다. 이 설정은 실제 일반 요청에 적용되며 프로필 GET으로만 제한되지 않는다. V1/V2의 API·인증·DB 호환성은 별도로 확인한다. ALB 가중치가 있는 타깃 그룹의 장애를 자동으로 다른 그룹에 전환해 주지는 않으므로 오류 발생 시 V2 비중을 0으로 적용한다.

로컬에서는 ALB 변경 권한이 있는 본인 프로필을 선택해 실행한다. 아래 경로의 저장소 `ecs` root를 사용하며, 이전에 준비했던 `/tmp`의 독립 실험 Terraform root는 적용하지 않는다. 동일 리스너의 실험 규칙을 별도 state에서 이미 생성했다면 중복 생성하지 말고 먼저 소유권을 정리한다.

```bash
export AWS_PROFILE='<apply 권한이 있는 프로필>'
terraform -chdir=ecs plan \
  -target=aws_lb_listener_rule.backend_canary \
  -target=aws_lb_listener_rule.backend_test \
  -out=/tmp/backend-canary.tfplan
terraform -chdir=ecs show -no-color /tmp/backend-canary.tfplan
terraform -chdir=ecs apply /tmp/backend-canary.tfplan
terraform -chdir=ecs output backend_canary_routing
```

기존 헤더 규칙이 state에 있는 최초 전환의 targeted plan 기대값은 `aws_lb_listener_rule.backend_test` → `aws_lb_listener_rule.backend_canary[0]` 주소 이동과 규칙 수정 1개다(추가·삭제 0개). 최초 전환 시 주소 이동의 양쪽을 포함하도록 두 target을 지정한다. 기존 헤더 조건은 제거되고 V1 100 / V2 0 가중치가 적용된다. 기존 규칙이 전혀 없는 새 환경에서는 추가 1개다. 기존 리스너·서비스·태스크 설정 변경은 없다. 이번 전환 실험에 한해 ALB 변경만 분리해 적용한다. Terraform의 `-target` 경고는 예상되며 일반적인 전체 인프라 적용에 상시 사용하지 않는다.

2026-10-17 확인 시 전체 plan은 ALB 규칙 변경 외에 ECS 권장 AMI 조회값 변경으로 Launch Template·ASG 변경 2개를 포함했다. 이 변경은 ALB 코드와 별개이며 위 대상 지정 plan에서는 제외된다. 전체 plan이나 CI apply에서는 다시 포함될 수 있으므로 별도 검토한다. 이후 전체 plan에 남은 변경을 확인하되, 검토 없이 apply하지 않는다.

확인 후 `variables.tf`의 `backend_canary_green_weight` 기본값을 `10 → 50 → 100`으로 단계마다 수정하고 새 plan/apply를 진행한다. 비율만 바꾸면 규칙 수정 1개가 예상된다. 현재 단계를 코드에 반영해 커밋하면 CI에서도 같은 값을 사용한다. 로컬 `-var`만 바꾸면 다음 CI가 코드의 기본값으로 되돌릴 수 있다. 가중치가 달라질 때마다 ALB 적용 값, HTTP 실패·프로필 불일치·지연, 타깃 및 ECS 상태를 확인한다.

실험 후 V1으로 복구할 때는 규칙을 유지하고 `backend_canary_green_weight=0`으로 수정·apply한다. `backend_canary_enabled=false`는 규칙 삭제용이며 기존 헤더 규칙을 복원하지 않는다. 이 경우 V2 타깃 그룹과 ALB 리스너의 연결도 없어지므로 V2 서비스 운영을 계속하는 일반적인 롤백에는 사용하지 않는다. 매번 새 plan을 생성하며, 이전 단계의 saved plan을 재사용하지 않는다. 로컬 apply와 CI apply를 동시에 실행하지 않는다.

## Backend (V1 DB 사용)

BE 레포 `dev` CI가 Public ECR(`stockspoon-v2-backend`)에 push한 이미지를 Service ASG(capacity provider `service`)에서 market-http와 함께 실행합니다.

- `backend_image_tag`는 최초 생성 리비전에만 쓰입니다. 이후 배포와 실행 설정은 BE 레포 `cd-ecs-v2.yaml`과 앱 템플릿이 담당합니다. (아래 [CD](#cd-be-레포-dev--ecs))

- **DB는 V1 EC2의 MySQL을 그대로 사용합니다.** V1 Compose가 `3306`을 호스트에 게시하고, 외부 접근은 V1 앱 SG로만 통제합니다. 3306은 Backend Task SG만 허용합니다. (`cross_root_rules.tf`) 접속 주소는 `app-server` output `app_private_ip`를 참조합니다.
  - EIP로 들어온 트래픽도 private IP로 전달되므로 바인딩 주소로는 외부 노출을 막을 수 없습니다. V1 앱 SG에 넓은 인바운드 규칙을 추가하면 3306도 함께 열립니다.
- V1 Backend(main 코드)와 같은 DB를 쓰므로 설정으로 운영 영향을 막습니다.
  - `JPA_DDL_AUTO`·`SPRING_JPA_HIBERNATE_DDL_AUTO=none`: dev 코드가 운영 스키마를 변경하지 않습니다. DB 이관 기간에는 V1 스키마를 고정하므로 검증(`validate`)도 하지 않아, dev에 테이블이 추가돼도 기동은 되고 해당 API만 SQL 오류가 납니다.
  - 키움 시세 스트림은 `backend_kiwoom_stream_enabled`(기본 `true`)로 켭니다. V1과 **별도로 발급한 키**(SSM `KIWOOM_APP_KEY`·`KIWOOM_APP_SECRET`)를 쓰므로 세션 충돌은 없습니다. 키움 허용 IP에 NAT Gateway EIP가 등록돼 있어야 합니다.
    - V1과 ECS가 같은 PENDING 지정가 주문을 동시에 체결하려 해도, 양쪽 코드(V1 main·dev) 모두 `executeLimit`에서 계좌 행을 `FOR UPDATE`로 잠근 뒤 주문이 아직 PENDING인지 다시 읽으므로 먼저 커밋한 쪽만 체결됩니다. 호출부(`OrderExecutionListener`)에 바깥 트랜잭션이 없어 주문 재조회가 락 이후 최신 커밋을 봅니다.
    - 끄면(`false`) ECS에서 주문 접수가 `MARKET_STREAM_UNAVAILABLE`로 거절될 수 있습니다. CD 적용 후에는 apply만으로 실행 중 Task가 바뀌지 않으므로 ECS 배포 job 재실행이 필요합니다.
  - `KIWOOM_COLLECTOR_ENABLED=false`: collector는 V1 운영 서버가 담당합니다.
  - `backend_desired_count=2`: 최초 생성 기본값이며 이후 Task 수는 Auto Scaling이 2~4개로 관리합니다. dev 코드의 주기 작업(만료 주문 정리)은 V1과 함께 운영 DB에 씁니다.
- Backend 트래픽은 위 Canary 가중치를 따릅니다. 초기 V2 비중은 0입니다. Canary를 비활성화하면 `/api/*` 요청도 V1 기본 경로로 전달됩니다.
- 헬스체크는 actuator가 없어 인증 없이 200을 주는 `/api/v1/auth/csrf`를 임시로 사용합니다. DB·Valkey 상태는 반영하지 않으므로 Canary 전에 `/actuator/health`로 교체합니다.
- Valkey는 운영 Valkey의 `backend` 사용자로 IAM 인증합니다. (Task Role에 Connect Policy 연결)

### Secret 등록

`/stockspoon/v2/prod/backend/<이름>`에 V1 운영 `.env`(`/opt/cloud/.env`)와 **같은 값**을 등록합니다. `JWT_SECRET`이 같아야 V1에서 발급한 로그인 쿠키가 ECS에서도 유효합니다.

| 이름 | 비고 |
|---|---|
| `MYSQL_USER`, `MYSQL_PASSWORD` | V1 MySQL 계정 |
| `JWT_SECRET` | V1과 동일 |
| `KAKAO_CLIENT_ID`, `KAKAO_CLIENT_SECRET`, `KAKAO_REDIRECT_URI` | V1 `.env`의 `KAKAO_CLIENT_SECRET`이 비어 있으면 등록하지 않고 `backend_kakao_client_secret_enabled = false` |
| `FRONTEND_ORIGIN` | V1과 동일 |

```bash
# 레포 밖 임시 파일에 V1 .env의 해당 줄만 복사한 뒤
scripts/put-ssm-env.sh backend /path/to/.env.backend
```

### 전환 순서

1. `app-server`에 `app_private_ip` output 추가 PR 머지·apply (리소스 변경 없음). 이 output이 state에 있어야 이 root의 plan이 성공합니다.
2. 위 Secret 등록
3. **장 마감 후** compose 3306 게시 PR 머지 → V1 서버에서 db만 재생성 (`git pull` 후 `docker compose --env-file .env up -d db`)
   - 머지 후 다음 V1 CD(`git pull` + 전체 `compose up`)도 db를 재생성하므로, 장중에 머지하지 않습니다.
   - 확인: `sudo ss -ltnp | grep 3306` → `0.0.0.0:3306` 표시, V1 backend 정상
4. 이 root PR 머지·apply: V1 앱 SG 규칙, Task Definition(dev 이미지), Valkey 정책
5. 확인: `curl -s https://stock-spoon.com/api/v1/auth/csrf`, Target Group healthy, 로그에 Hikari·Valkey 연결 오류 없음. curl은 현재 가중치의 대상을 확인하며 V2 직행 테스트가 아님

롤백: 이전 Task Definition 리비전으로 `update-service`합니다. 서비스를 0개로 중단하려면 먼저 Auto Scaling의 예약·동적 확장을 중단하고 최소치를 0으로 조정한 뒤 서비스 desired를 0으로 변경합니다. `desired_count`는 Terraform이 무시하므로 변수 변경만으로 중단되지 않습니다. DB 경로까지 닫으려면 SG 규칙 제거 후 compose `ports`를 되돌리고 db를 재생성합니다.

### 변경 책임

| 대상 | 관리 주체 | 적용 경로 |
|---|---|---|
| 이미지 SHA, CPU·메모리, 환경변수, Secret 참조, 컨테이너 헬스체크 | BE·AI 앱/CD | 앱 레포 `.aws/ecs/*.json` 변경 → CD 등록·배포·검증 |
| 클러스터, 서비스 용량·배포 정책, ALB, IAM 정책, SG·네트워크 | Cloud | Terraform plan·apply |
| 포트, Role ARN, DB·Valkey 주소, Secret 경로 등 양쪽에 연결된 값 | 앱 담당자와 Cloud 공동 검토 | Cloud 리소스 준비 → 앱 템플릿 변경·배포 → 이전 리소스 정리 |

템플릿을 옮기는 것만으로 소유권이 분리되지는 않습니다. 두 서비스의 `task_definition` 변경은 Terraform에서 무시하고, Terraform의 기존 Task Definition은 최초 생성용으로 실행 필드를 동결합니다. `skip_destroy`는 등록 해제 방지만 담당하며, 후속 리비전 생성을 막는 것은 실행 필드의 `ignore_changes`입니다. 기존 Terraform Task Definition에서 실행 설정을 변경하는 방식은 사용하지 않습니다.

기존 Task Definition 리소스를 제거하거나 이름을 바꾸는 별도 정리는 이 변경에 포함하지 않습니다. 최초 생성용 리소스는 state에 유지하며, 향후 완전히 제거할 경우에도 AWS 등록 해제 없이 state 소유권을 해제하는 절차가 필요합니다.

### CD (BE 레포 dev → ECS)

`dev` push → `ci-dev.yaml`(빌드·이미지 push) → `cd-dev.yaml`(V2 개발 EC2) 성공 → `cd-ecs-v2.yaml`(이 서비스) 순서로 배포합니다.

1. BE 커밋의 `.aws/ecs/backend.json`에 검증한 `:<dev 커밋 SHA>` 이미지를 주입해 새 리비전을 등록합니다. 환경변수·Secret 참조·헬스체크·CPU·메모리도 이 템플릿이 관리합니다.
2. 서비스를 새 리비전으로 갱신하고, 그 배포의 `rolloutState`가 `COMPLETED`가 될 때까지 기다립니다. Circuit Breaker가 롤백하면(`FAILED`) 워크플로도 실패합니다.

- 서비스에 `ignore_changes = [task_definition]`이 있으므로 apply가 CD 배포를 되돌리지 않습니다.
- 최초 생성용 Terraform Task Definition의 실행 설정은 동결합니다. 기존 서비스의 실행 설정은 앱 템플릿을 수정하고 CD로 적용합니다.
- 배포 Role(`stockspoon-v2-prod-github-actions-backend-deploy`)은 BE 레포 `dev` ref의 OIDC 토큰만 신뢰하며, backend 서비스 갱신과 backend Task Role PassRole만 허용합니다. AI 배포 Role과 분리되어 있습니다.
- `dev` 커밋마다 **운영 DB(V1 MySQL)에 붙는** 이 서비스가 교체됩니다. V1 DB 사용 기간의 주의 사항(스키마 고정, 데이터 변경 테스트 금지)은 위와 같습니다.

| 이름 | 위치 | 값 |
|---|---|---|
| `AWS_V2_ECS_DEPLOY_ROLE_ARN` | GitHub Secret (KTB4-11th-BE) | output `github_actions_backend_deploy_role_arn` |

적용 순서 (feat/94 apply로 서비스가 dev 이미지·8080으로 바뀐 **뒤에** 진행):

1. 이 변경 apply: 배포 Role 생성, 서비스 `ignore_changes` 추가 (서비스·Task Definition 변경 없음)
2. BE 레포 Secret `AWS_V2_ECS_DEPLOY_ROLE_ARN` 등록
3. BE 레포 CD PR을 `dev`에 머지 → 그 머지 커밋으로 첫 ECS 배포
4. 확인: Actions 요약의 Task Definition 리비전과 V2 타깃 상태. `curl -s https://stock-spoon.com/api/v1/auth/csrf`는 현재 ALB 가중치에 따라 전달되므로 V2 배포 검증으로 단독 사용하지 않는다.

## ProxySQL DB migration rehearsal

ProxySQL은 Backend와 별도 ECS 서비스로 실행하며, 우선 `private_subnet_ids[0]`의 단일 AZ에 Task 1개를 둡니다. 이번 단계에서는 Backend의 ProxySQL 접속 주소를 만들지 않습니다. ProxySQL Task SG는 V1 DB와 이관 DB의 3306 및 ECS Exec용 HTTPS만 허용하고, 다른 root가 소유한 두 DB 보안그룹에도 ProxySQL Task SG만 허용하는 규칙을 추가합니다.

이 첫 단계는 ProxySQL 컨테이너 기동과 DB 네트워크 연결을 확인하기 위한 구성입니다. ProxySQL의 `mysql_servers`·`mysql_users`는 비워 두므로 아직 쿼리를 DB로 전달하지 않습니다. Backend의 `SPRING_DATASOURCE_URL`도 바꾸지 않습니다. `mysql-network-check` sidecar는 시작 시 V1 및 이관 DB의 3306에 TCP 연결을 확인하고 결과를 같은 CloudWatch Log Group에 기록합니다.

적용 후 확인 예시:

```bash
aws logs tail "$(terraform -chdir=ecs output -raw proxysql_log_group_name)" --since 10m --follow
```

`mysql-network-check` 로그에서 각 DB에 대해 `TCP_OK <private-ip>:3306`을 확인합니다. 이 확인은 ProxySQL ECS 태스크에서 DB까지 TCP 연결만 검증하며, DB 인증이나 실제 SQL 라우팅은 아직 검증하지 않습니다. Backend가 ProxySQL에 연결하도록 바꾸려면 이후 고정 주소 또는 서비스 검색을 별도로 구성해야 합니다.

비용은 NLB 없이 계산합니다. ECS EC2 시작 유형에는 태스크별 ECS 요금이 없으며, ProxySQL 태스크는 기존 `c6i.xlarge` Capacity Provider의 여유 자원을 먼저 사용합니다. 여유 용량에 배치되면 별도 EC2 비용은 없고 로그 사용량에 따른 CloudWatch Logs 비용만 추가될 수 있습니다. 용량 부족으로 ASG가 `c6i.xlarge` 한 대를 더 띄우면 서울 리전 Linux On-Demand 기준 약 `$140.16/월`이며, 30 GiB gp3 볼륨 약 `$2.74/월`을 더해 총 `$142.90/월` 정도입니다(730시간 가정). 이는 공개 지역별 요금표를 이용한 추정치로, 구매 옵션·실제 사용량·세금에 따라 달라집니다. [c6i.xlarge 요금 참고](https://aws-pricing.com/c6i.xlarge.html), [서울 리전 gp3 요금 참고](https://aws-pricing.com/ap-northeast-2.html).

## AI market-http

AI 레포의 통합 이미지(Public ECR `stockspoon-v1-ai`)를 `command = ["market-http"]`로 실행합니다. Service ASG(capacity provider `service`)에 배치합니다.

- `ai_image_tag`가 비어 있으면 Task Definition과 Service는 만들지 않고 SG·Target Group·리스너 규칙·Role만 준비합니다. 최초 생성 때는 이 값으로 초기 이미지를 지정합니다.
- 이후 Task Definition과 배포는 AI 레포 `cd-ecs-v2.yaml`이 담당합니다. 성공한 CI의 커밋 SHA를 같은 커밋의 `.aws/ecs/market-http.json`에 주입해 새 리비전을 등록합니다. 환경변수·Secret 참조·컨테이너 헬스체크·CPU·메모리는 앱 템플릿을 수정하고 CD로 적용합니다.
- Terraform은 클러스터·서비스·ALB·IAM·네트워크를 관리합니다. 서비스의 `task_definition`은 무시하고, 최초 생성용 Task Definition은 실행 필드를 `ignore_changes`로 동결하고 `skip_destroy = true`로 등록 해제를 방지합니다. 최초 생성용 HCL의 실행 설정을 바꿔도 기존 서비스에는 반영되지 않습니다.
- BE도 동일하게 `.aws/ecs/backend.json`과 `cd-ecs-v2.yaml`에서 실행 설정과 리비전을 관리합니다. 개발 EC2 배포 이후 같은 SHA로 ECS를 배포합니다.
- Cloud 검증은 실제 서비스의 배포 완료·태스크 수·참조 Task Definition의 ACTIVE 상태를 검사합니다. Terraform 최초 생성 리비전과의 일치 여부는 검사하지 않으며, 배포한 리비전의 성공 여부는 앱 CD가 확인합니다.
- 이미지 조회 Python 스크립트와 external provider는 사용하지 않습니다. 최초 배포는 Cloud로 서비스를 생성한 뒤 앱 CD를 실행합니다. 기존 환경 이전은 앱 템플릿과 현재 실행 설정을 검토한 뒤 Cloud 변경을 먼저 적용하고 앱 CD를 실행합니다.
- 과거 시세(`/market/bars`)는 **V1 AI 운영 서버** QuestDB(`9000`)를 조회합니다. AI Compose가 `AI_PRIVATE_IP`에만 게시하고, AI SG는 market-http Task SG만 허용합니다. QuestDB `9000`은 인증 없이 SQL을 실행할 수 있으므로 SG와 private IP 바인딩으로만 막고 있습니다.
- 현재가(`/market/prices`)는 Valkey를 먼저 읽고, 없으면 QuestDB 최근 1분봉으로 채워 Valkey에 저장합니다. 이 저장에는 TTL이 없고 V2에는 현재가를 갱신하는 서비스(market-streamer)가 없으므로, **처음 조회된 값이 고정됩니다.** 현재는 `/market/bars`만 검증 대상으로 보고, `/market/prices`는 AI 코드 수정(TTL) 전까지 사용하지 않습니다.
- market-streamer(키움 실시간 → Valkey)는 V2 ECS에서 운영하지 않습니다.

| 서비스 | Task | 개수 | 배포 |
|---|---|---|---|
| market-http | 2 vCPU / 4 GiB (uvicorn 단일 프로세스, 부하 테스트로 보정) | 기본 2, Auto Scaling 2~4, AZ·인스턴스 분산 | Rolling 100/200, Circuit Breaker |

### ECS 배포 Role 신뢰 조건

`ci_deploy_role.tf`의 배포 Role은 GitHub OIDC 토큰의 `sub`가 `ecs_deploy_github_subjects`(기본: AI 레포 `dev`)와 정확히 일치할 때만 assume됩니다. 기능 브랜치·PR·`main`·다른 레포에서는 운영 ECS에 배포할 수 없습니다.

`cd-ecs-v2.yaml`은 `workflow_run`으로 실행되며, `workflow_run` 워크플로는 **레포의 기본 브랜치**에서 실행된 것으로 처리되어 `sub`가 `ref:refs/heads/<기본 브랜치>`가 됩니다. 현재 AI 레포 기본 브랜치가 `dev`이므로 `refs/heads/dev`로 일치합니다.

> **TODO:** AI 레포의 GitHub 기본 브랜치를 `dev`에서 다른 브랜치(예: `main`)로 바꾸면 `sub`가 `refs/heads/main`으로 바뀌어 `cd-ecs-v2` 배포가 `AssumeRoleWithWebIdentity` 단계에서 실패합니다. 기본 브랜치를 바꿀 때 `variables.tf`의 `ecs_deploy_github_subjects`를 함께 수정하고 apply합니다.

### GitHub Variable

| 이름 | 위치 | 사용처 |
|---|---|---|
| `AWS_ECS_DEPLOY_ROLE_ARN` | GitHub Variable (KTB4-11th-AI) | `cd-ecs-v2.yaml` (ECS 배포 Role, output `github_actions_ecs_deploy_role_arn`) |
| `PUBLIC_ECR_AI_REPOSITORY_URI` | GitHub Variable (KTB4-11th-AI) | `cd-ecs-v2.yaml` 배포 이미지 주소 (CI Dev가 push한 `:<커밋 SHA>`) |

### 전환 순서

1. 이 root apply (`ai_image_tag` 비움): SG·Target Group·`/market/*` 규칙·Task Role·ECS 배포 Role 생성
2. AI 레포 Variable `AWS_ECS_DEPLOY_ROLE_ARN`에 output `github_actions_ecs_deploy_role_arn` 등록
3. 운영 AI 서버 QuestDB `9000`이 `AI_PRIVATE_IP`에 게시됐는지 확인: `sudo ss -ltnp | grep :9000`
4. `ai_image_tag`를 CI에서 검증하고 ECR에 업로드한 커밋 SHA로 설정해 apply → market-http 서비스 최초 생성
5. 확인: Target Group healthy, `/market/health`, `/market/bars/005930?timeframe=1d&limit=5`

롤백: 이미지 문제는 이전 Task Definition 리비전으로 `aws ecs update-service --task-definition <이전 ARN>`. 서비스를 제거하려면 `ai_image_tag`를 비우고 apply합니다.

## 실험 관측

CloudWatch 전용 대시보드, ASG 지표, ECS·ASG 이벤트 보존, 서비스 건강 알람, 실험 마커·k6 원시 결과 업로드 절차는 [실험 관측 운영 안내](OBSERVABILITY.md)를 참고합니다. FIS 실험·실제 부하·알림 수신자 설정은 자동으로 실행하지 않습니다.
