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
| `svc_market_common.tf` | market-http 공통 값 (이미지, V1 AI private IP, Valkey 접속 정보) |
| `svc_market_http.tf` | market-http(Socket) 로그 그룹, Task Role(Valkey `socket`), Task SG, Target Group, Task Definition, ECS Service |
| `ci_deploy_role.tf` | AI 레포 `cd-ecs-v2.yaml`이 assume하는 ECS 배포 Role (Task Definition 등록, market 서비스 갱신, Task Role PassRole) |
| `cross_root_rules.tf` | ALB SG → Task egress, HTTPS 리스너 규칙(Backend 테스트, market-http `/market/*`), V1 AI SG ingress(QuestDB) |

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
