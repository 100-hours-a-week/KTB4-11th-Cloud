# ECS

운영 ECS 클러스터와 서비스를 관리하는 Terraform root입니다.
V1 EC2에서 실행 중인 Backend를 ECS로 이전하고, 이후 역할별 서비스(Socket, Market Data, Match Engine)를 같은 클러스터에 추가합니다.

## 참조 관계

```
ecs ──참조──> shared-infra      (VPC, Private Subnet)
    ──참조──> app-server        (ALB 리스너, Blue TG, ALB·V1 앱 SG, AI Public ECR)
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
| `svc_backend.tf` | Backend 로그 그룹, Task Role, Task SG, Green Target Group, Task Definition, ECS Service |
| `svc_market_common.tf` | AI market 서비스 공통 값 (이미지, V1 AI private IP, Valkey 접속 정보) |
| `svc_market_http.tf` | market-http(Socket) 로그 그룹, Task Role(Valkey `socket`), Task SG, Target Group, Task Definition, ECS Service |
| `svc_market_streamer.tf` | market-streamer(Market Data) 로그 그룹, Task Role(Valkey `market-data`), Task SG, Task Definition, ECS Service |
| `cross_root_rules.tf` | ALB SG → Task egress, HTTPS 리스너 규칙(Backend 테스트, market-http `/market/*`), V1 AI SG ingress(QuestDB·PostgreSQL) |

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
curl -s -H 'X-StockSpoon-Target: ecs' https://stock-spoon.com/api/

# market-http
curl -s 'https://stock-spoon.com/market/prices?codes=005930'
curl -sN 'https://stock-spoon.com/market/prices/stream?codes=005930'   # SSE
curl -s 'https://stock-spoon.com/market/bars/005930?timeframe=1d&limit=5'
```

## AI market 서비스 (market-http, market-streamer)

AI 레포의 통합 이미지(Public ECR `stockspoon-v1-ai`)를 운영 Compose와 같이 `command`로 진입점을 골라 실행합니다.

- `ai_image_tag`(AI `main` 커밋 SHA)가 비어 있으면 Task Definition과 Service는 만들지 않고 SG·Target Group·리스너 규칙·Role만 준비합니다.
- 데이터 저장소는 당분간 **V1 AI 운영 서버**의 QuestDB(`9000`, market-http)와 PostgreSQL(`5432`, market-streamer)을 사용합니다. AI Compose가 두 포트를 `AI_PRIVATE_IP`에만 게시하고, AI SG는 각 Task SG만 허용합니다. V1 AI 서버가 단일 장애 지점이므로 V2 저장소로 이전할 때 `cross_root_rules.tf`의 AI SG 규칙과 함께 정리합니다.
- QuestDB `9000`은 인증 없이 SQL을 실행할 수 있는 포트입니다. 현재는 SG와 private IP 바인딩으로만 막으며, Basic Auth 도입은 후속 작업입니다.

| 서비스 | Task | 개수 | 배포 |
|---|---|---|---|
| market-http | 1 vCPU / 1 GiB (uvicorn 단일 프로세스) | 2, AZ·인스턴스 분산 | Rolling 100/200, Circuit Breaker |
| market-streamer | 0.25 vCPU / 512 MiB | 1 고정 | 0/100 (기존 Task를 먼저 내려 키움 세션 중복 방지), 장 마감 후 배포 |

market-streamer는 `STOP_AT`(KST)에 exit 0 하고, 그 이후에 시작하면 바로 종료하는 배치 구조입니다. 앱 기본값(15:40)으로 ECS Service에서 돌리면 장 마감 후 재시작을 반복하므로, 코드 변경 없이 `MARKET_STREAMER_STOP_AT=23:59`로 두어 하루 1번 재시작하는 상주 서비스처럼 운영합니다. 장외 시간에는 키움 세션만 유지되고 수신 데이터는 없습니다. 장 시간에만 실행하려면 Application Auto Scaling 예약 액션이 필요하며, Terraform CI 권한(`application-autoscaling:*`)을 먼저 추가해야 합니다. Worker ASG 도입 전까지 Service ASG에서 실행합니다.

### Secret · Variable 이름 목록

값은 Terraform·문서에 두지 않고 CLI로 직접 등록합니다. (값이 state에 남지 않게)

| 이름 | 위치 | 사용처 |
|---|---|---|
| `/stockspoon/v2/prod/market-streamer/POSTGRES_DSN` | SSM SecureString | market-streamer Task |
| `/stockspoon/v2/prod/market-streamer/KIWOOM_APP_KEY` | SSM SecureString | market-streamer Task |
| `/stockspoon/v2/prod/market-streamer/KIWOOM_SECRET_KEY` | SSM SecureString | market-streamer Task |
| `AWS_ECS_DEPLOY_ROLE_ARN` | GitHub Variable (KTB4-11th-AI) | `cd-ecs-v2.yaml` (ECS 배포 Role, 이 root에서 생성 예정) |
| `AWS_ECR_PUSH_ROLE_ARN`, `PUBLIC_ECR_AI_REPOSITORY_URI` | GitHub Variable (KTB4-11th-AI) | `cd-ecs-v2.yaml` 이미지 빌드·push |

### market-streamer Secret 등록

```bash
for name in POSTGRES_DSN KIWOOM_APP_KEY KIWOOM_SECRET_KEY; do
  aws ssm put-parameter --type SecureString \
    --name "/stockspoon/v2/prod/market-streamer/$name" --value '<값>'
done
# POSTGRES_DSN 예: postgresql+psycopg://<user>:<password>@<V1 AI private IP>:5432/<db>
```

### 전환 순서

1. AI 운영 서버 `~/ai/.env`에 `AI_PRIVATE_IP` 추가 → AI CD로 Compose 포트 게시 (postgres·questdb 컨테이너가 재생성되므로 장 마감 후)
2. 키움 앱키 허용 IP에 NAT Gateway EIP(`shared-infra` output `nat_gateway_public_ip`) 등록 여부 확인
3. 위 SSM Secret 등록
4. `ai_image_tag`를 market 서비스가 포함된 AI `main` SHA로 설정해 apply
5. market-http 확인 후, portfolio-builder의 `PORTFOLIO_BUILDER_MARKET_HTTP_BASE_URI`를 ECS 경로로 변경하고 EC2 market-http 제거
6. **장 마감 후** EC2 `ktb-market-streamer.timer` 비활성화(AI CD의 timer 목록에서도 제거)와 동시에 ECS market-streamer 확인. 두 곳이 동시에 키움 세션을 열지 않도록 한다.

롤백: market-streamer는 ECS Service `desired_count`를 0으로 내리고 EC2 timer를 다시 활성화합니다.
