# ECS

운영 ECS 클러스터와 서비스를 관리하는 Terraform root입니다.
V1 EC2에서 실행 중인 Backend를 ECS로 이전하고, 이후 역할별 서비스(Socket, Market Data, Match Engine)를 같은 클러스터에 추가합니다.

## 참조 관계

```
ecs ──참조──> shared-infra   (VPC, Private Subnet)
    ──참조──> app-server     (ALB 리스너, Blue TG, ALB·V1 앱 SG)
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
| `cross_root_rules.tf` | ALB SG → Backend Task egress, HTTPS 리스너 테스트 규칙 |

## 용량 설계

- Service ASG 인스턴스는 기준 Task 조합(Backend 1 + Socket 1 = 3 vCPU / 5 GiB)에 20% Headroom을 적용한 3.75 vCPU / 6.25 GiB를 충족하는 `c6i.xlarge`입니다.
- Headroom은 인스턴스 크기에서 확보하므로 Capacity Provider `target_capacity`는 100입니다.
- ASG는 min 2로 2a·2c에 1대씩 배치합니다. Backend Task는 AZ → 인스턴스 순서로 분산합니다.

## ECS로 테스트 요청 보내기

운영 트래픽은 그대로 V1(Blue)으로 가고, 테스트 헤더가 있는 요청만 ECS(Green)로 전달됩니다.

```bash
curl -s -H 'X-StockSpoon-Target: ecs' https://stock-spoon.com/
```
