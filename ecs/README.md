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
| `cross_root_rules.tf` | 다른 root 소유 리소스에 추가하는 규칙 (리스너 규칙, SG 규칙) |

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
| `svc_market_http.tf` | market-http(Socket) 로그 그룹, Task Role(Valkey `socket`), Task SG, Target Group, Task Definition, ECS Service |
| `ci_deploy_role.tf` | AI 레포 `cd-ecs-v2.yaml`이 assume하는 ECS 배포 Role (Task Definition 등록, market 서비스 갱신, Task Role PassRole) |
| `cross_root_rules.tf` | ALB SG → Task egress, HTTPS 리스너 규칙(Backend 테스트, market-http `/market/*`), V1 AI SG ingress(QuestDB), V1 앱 SG ingress(MySQL) |

## 용량 설계

- Service ASG 인스턴스는 기준 Task 조합(Backend 1 + Socket 1 = 3 vCPU / 5 GiB)에 20% Headroom을 적용한 3.75 vCPU / 6.25 GiB를 충족하는 `c6i.xlarge`입니다.
- Headroom은 인스턴스 크기에서 확보하므로 Capacity Provider `target_capacity`는 100입니다.
- ASG는 min 2로 2a·2c에 1대씩 배치합니다. Backend Task는 AZ → 인스턴스 순서로 분산합니다.

## 경로 라우팅

| 경로 | 대상 | 비고 |
|---|---|---|
| `/api/*` + 테스트 헤더 | ECS Backend(Green) | 운영 트래픽은 V1(Blue). Canary 단계에서 가중치 규칙으로 교체 |
| `/market/*` | ECS market-http | ALB가 `/market` 접두사를 제거해 전달 (`/market/prices` → `/prices`). V1에 없는 경로라 헤더 없이 바로 운영 |
| 그 외 | V1 EC2 (기본 action) | |

```bash
# ECS Backend 테스트 (운영 트래픽은 그대로 V1)
curl -s -H 'X-StockSpoon-Target: ecs' https://stock-spoon.com/api/v1/auth/csrf

# market-http
curl -s 'https://stock-spoon.com/market/prices?codes=005930'
curl -sN 'https://stock-spoon.com/market/prices/stream?codes=005930'   # SSE
curl -s 'https://stock-spoon.com/market/bars/005930?timeframe=1d&limit=5'
```

## Backend (V1 DB 사용)

BE 레포 `dev` CI가 Public ECR(`stockspoon-v2-backend`)에 push한 이미지를 `backend_image_tag`(dev 커밋 SHA)로 실행합니다. 이미지를 바꿀 때는 이 값을 바꿔 apply합니다.

- **DB는 V1 EC2의 MySQL을 그대로 사용합니다.** V1 Compose가 `3306`을 호스트에 게시하고, 외부 접근은 V1 앱 SG로만 통제합니다. 3306은 Backend Task SG만 허용합니다. (`cross_root_rules.tf`) 접속 주소는 `app-server` output `app_private_ip`를 참조합니다.
  - EIP로 들어온 트래픽도 private IP로 전달되므로 바인딩 주소로는 외부 노출을 막을 수 없습니다. V1 앱 SG에 넓은 인바운드 규칙을 추가하면 3306도 함께 열립니다.
- V1 Backend(main 코드)와 같은 DB를 쓰므로 설정으로 운영 영향을 막습니다.
  - `JPA_DDL_AUTO`·`SPRING_JPA_HIBERNATE_DDL_AUTO=none`: dev 코드가 운영 스키마를 변경하지 않습니다. DB 이관 기간에는 V1 스키마를 고정하므로 검증(`validate`)도 하지 않아, dev에 테이블이 추가돼도 기동은 되고 해당 API만 SQL 오류가 납니다.
  - 키움 시세 스트림은 `backend_kiwoom_stream_enabled`(기본 `true`)로 켭니다. V1과 **별도로 발급한 키**(SSM `KIWOOM_APP_KEY`·`KIWOOM_APP_SECRET`)를 쓰므로 세션 충돌은 없습니다. 키움 허용 IP에 NAT Gateway EIP가 등록돼 있어야 합니다.
    - V1과 ECS가 같은 PENDING 지정가 주문을 동시에 체결하려 해도, 양쪽 코드(V1 main·dev) 모두 `executeLimit`에서 계좌 행을 `FOR UPDATE`로 잠근 뒤 주문이 아직 PENDING인지 다시 읽으므로 먼저 커밋한 쪽만 체결됩니다. 호출부(`OrderExecutionListener`)에 바깥 트랜잭션이 없어 주문 재조회가 락 이후 최신 커밋을 봅니다.
    - 끄면(`false`) ECS에서 주문 접수가 `MARKET_STREAM_UNAVAILABLE`로 거절될 수 있습니다. CD 적용 후에는 apply만으로 실행 중 Task가 바뀌지 않으므로 ECS 배포 job 재실행이 필요합니다.
  - `KIWOOM_COLLECTOR_ENABLED=false`: collector는 V1 운영 서버가 담당합니다.
  - `backend_desired_count=1`: dev 코드의 주기 작업(만료 주문 정리)이 V1과 함께 운영 DB에 씁니다. 동시 실행 안전성을 BE와 확인한 뒤 늘립니다.
- 운영 트래픽은 받지 않습니다. 테스트 헤더(`X-StockSpoon-Target: ecs`)가 있는 `/api/*` 요청만 들어옵니다.
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
5. 확인: `curl -s -H 'X-StockSpoon-Target: ecs' https://stock-spoon.com/api/v1/auth/csrf`, Target Group healthy, 로그에 Hikari·Valkey 연결 오류 없음

롤백: `backend_desired_count = 0`으로 apply하거나 이전 Task Definition 리비전으로 `update-service`. DB 경로까지 닫으려면 SG 규칙 제거 후 compose `ports`를 되돌리고 db를 재생성합니다.

## AI market-http

AI 레포의 통합 이미지(Public ECR `stockspoon-v1-ai`)를 `command = ["market-http"]`로 실행합니다. Service ASG(capacity provider `service`)에 배치합니다.

- `ai_image_tag`(AI `dev` 커밋 SHA)가 비어 있으면 Task Definition과 Service는 만들지 않고 SG·Target Group·리스너 규칙·Role만 준비합니다. 이 값은 **서비스를 처음 만들 때만** 쓰입니다.
- 이후 배포는 AI 레포 `cd-ecs-v2.yaml`이 담당합니다. `dev`의 CI Dev가 성공하면 그 커밋 이미지로 최신 Task Definition의 이미지만 바꿔 새 리비전을 등록하고 서비스를 갱신합니다. `ignore_changes = [task_definition]`이므로 apply가 CD 배포를 되돌리지 않습니다.
- 과거 시세(`/market/bars`)는 **V1 AI 운영 서버** QuestDB(`9000`)를 조회합니다. AI Compose가 `AI_PRIVATE_IP`에만 게시하고, AI SG는 market-http Task SG만 허용합니다. QuestDB `9000`은 인증 없이 SQL을 실행할 수 있으므로 SG와 private IP 바인딩으로만 막고 있습니다.
- 현재가(`/market/prices`)는 Valkey를 먼저 읽고, 없으면 QuestDB 최근 1분봉으로 채워 Valkey에 저장합니다. 이 저장에는 TTL이 없고 V2에는 현재가를 갱신하는 서비스(market-streamer)가 없으므로, **처음 조회된 값이 고정됩니다.** 현재는 `/market/bars`만 검증 대상으로 보고, `/market/prices`는 AI 코드 수정(TTL) 전까지 사용하지 않습니다.
- market-streamer(키움 실시간 → Valkey)는 V2 ECS에서 운영하지 않습니다.

| 서비스 | Task | 개수 | 배포 |
|---|---|---|---|
| market-http | 1 vCPU / 1 GiB (uvicorn 단일 프로세스) | 2, AZ·인스턴스 분산 | Rolling 100/200, Circuit Breaker |

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
4. `ai_image_tag`를 AI `dev` 커밋 SHA(CI Dev가 push한 이미지)로 설정해 apply → market-http 서비스 생성
5. 확인: Target Group healthy, `/market/health`, `/market/bars/005930?timeframe=1d&limit=5`

롤백: 이미지 문제는 이전 Task Definition 리비전으로 `aws ecs update-service --task-definition <이전 ARN>`. 서비스를 제거하려면 `ai_image_tag`를 비우고 apply합니다.
