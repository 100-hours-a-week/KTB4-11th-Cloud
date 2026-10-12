# 테스트 및 개발 인프라

이 디렉터리는 부하 테스트용 VPC와 EC2 인스턴스, StockSpoon V2 개발용 애플리케이션 EC2를 관리한다. 같은 VPC를 AI와 Valkey를 포함한 개발 환경의 공용 네트워크로도 사용한다.

Terraform 상태는 운영 인프라와 분리해 다음 위치에 저장한다.

- S3 버킷: `stockspoon-terraform-state-v1`
- State Key: `test-infra/terraform.tfstate`
- 리전: `ap-northeast-2`

## 구성 리소스

### 네트워크

- VPC: `10.20.0.0/16`
- Public Subnet: `10.20.1.0/24`, `ap-northeast-2a`
- Internet Gateway와 Public 기본 경로
- 개발 환경 공용 Private Subnet 2개
  - `10.20.10.0/24`, `ap-northeast-2a`
  - `10.20.11.0/24`, `ap-northeast-2c`
- Private Subnet 전용 Route Table

Private Route Table에는 VPC 내부 통신을 위한 `local` 경로만 존재한다. Internet Gateway와 NAT Gateway 경로는 추가하지 않는다.

Apply 전에 VPC 및 Subnet CIDR이 기존 VPC나 연결된 네트워크와 겹치지 않는지 확인해야 한다.

### 테스트 서버

- 애플리케이션 EC2
  - 기본 인스턴스 유형: `t3a.medium`
  - 고정 Elastic IP 사용
  - Docker 및 Docker Compose 설치
  - Cloud 저장소를 `/opt/cloud`에 복제
- k6 부하 테스트 EC2
  - 기본 인스턴스 유형: `t3a.medium`
  - Grafana 공식 Debian/Ubuntu 저장소를 통해 k6 설치
- 서버별 Security Group과 EC2 Instance Profile
- 기존 `stockspoon-v1-deploy` EC2 Key Pair 사용
- SSM Session Manager 사용 가능

### 개발 애플리케이션 서버

- 단일 EC2에서 수동 배치한 V2 Compose의 Nginx, Frontend, Backend, MySQL 실행
- 기본 인스턴스 유형: `t3a.medium`
- 암호화된 gp3 루트 볼륨: 기본 40 GiB
- 고정 Elastic IP 사용
- 개발 전용 Security Group과 Instance Profile
- IMDSv2 필수, Docker 컨테이너의 Instance Profile 자격 증명 사용을 위해 hop limit 2 설정
- Docker와 Docker Compose 설치 후 앱 파일을 둘 `/opt/stockspoon-v2` 디렉터리 생성
- `docker-compose.yaml`의 awslogs는 기존 `/stockspoon/app/containers/*` 로그 그룹을 사용
- 개발 Security Group은 HTTP 80만 공개하며 HTTPS 443은 열지 않음
- Cloud 저장소를 clone하거나 pull하지 않음. Compose 파일과 `.env`는 사용자가 EC2에 직접 배치
- FE·BE CD는 EC2의 `/opt/stockspoon-v2/.env`에서 자기 태그만 바꾸고 해당 Compose 서비스만 갱신
- V2 개발 이미지는 `stockspoon-v2-frontend`, `stockspoon-v2-backend` Public ECR 저장소를 사용

Compose의 명시적 메모리 제한은 합계 약 3.1 GiB다. `t3a.small`의 메모리 2 GiB로는 실행할 수 없어 기본값은 `t3a.medium`으로 둔다. 개발 전용 Security Group은 HTTP 80과 설정된 SSH CIDR만 외부에서 받고, AI 및 Valkey Terraform은 개발 전용 Security Group과 IAM Role만 허용한다. 기존 loadtest EC2의 보안 그룹, 역할, 실행 상태는 변경하지 않는다.

개발 도메인은 HTTP로 제공한다. HTTP는 브라우저와 서버 사이 트래픽을 암호화하지 않으므로 개발 데이터와 테스트 계정만 사용한다. 인증 쿠키는 `AUTH_COOKIE_SECURE=false`로 설정하고, OAuth 제공자에도 `http://개발도메인/auth/kakao/callback` 주소를 등록한다.

MySQL `db-data` 볼륨은 EC2의 암호화된 루트 디스크에 저장된다. 서버를 중지해도 데이터는 유지되지만 EC2를 Terraform에서 제거하면 함께 삭제된다.

기존 loadtest 애플리케이션 EC2는 HTTP와 HTTPS 요청을 외부에서 받을 수 있다. SSH는 기본적으로 `0.0.0.0/0`에서 허용되므로, 필요한 경우 로컬 `terraform.tfvars`의 `ssh_allowed_cidrs`를 접속할 공인 IP의 `/32` CIDR로 제한한다. 개발 EC2에는 별도 Security Group이 연결되고 외부 HTTPS는 허용하지 않는다.

### 로그 및 모니터링

- 애플리케이션 EC2에서 기존 StockSpoon 애플리케이션 CloudWatch Log Group에 로그 기록
- 애플리케이션 및 k6 서버용 CloudWatch Agent IAM 권한
- 보존 기간이 14일인 테스트 시스템 Log Group

CloudWatch Agent 수동 설치 방법은 [CLOUDWATCH_AGENT.md](CLOUDWATCH_AGENT.md), 공통 설정은 [cloudwatch-agent.json](cloudwatch-agent.json)을 참고한다.

## 애플리케이션 초기화 범위

개발 앱 EC2의 Bootstrap은 Docker와 Compose만 설치한다. 기존 EC2에서 수동으로 사용할 디렉터리와 파일을 준비한다.

```bash
ssh -i /path/to/stockspoon-v1-deploy.pem ubuntu@<dev-app-public-ip> \
  'sudo mkdir -p /opt/stockspoon-v2/nginx && sudo chown -R ubuntu:ubuntu /opt/stockspoon-v2'

scp -i /path/to/stockspoon-v1-deploy.pem \
  test-infra/dev-app/docker-compose.yaml \
  ubuntu@<dev-app-public-ip>:/opt/stockspoon-v2/docker-compose.yaml
scp -i /path/to/stockspoon-v1-deploy.pem \
  test-infra/dev-app/nginx/default.conf \
  ubuntu@<dev-app-public-ip>:/opt/stockspoon-v2/nginx/default.conf
scp -i /path/to/stockspoon-v1-deploy.pem \
  test-infra/dev-app/.env.example \
  ubuntu@<dev-app-public-ip>:/opt/stockspoon-v2/.env
```

EC2에서 `.env`의 placeholder를 개발용 값으로 바꾸고 `chmod 600 /opt/stockspoon-v2/.env`를 실행한다. `FE_TAG`, `BE_TAG`는 첫 각 서비스 CD가 자기 SHA로 바꾸므로 처음에는 non-empty placeholder여도 된다. `KAKAO_REDIRECT_URI`는 `http://개발도메인/auth/kakao/callback`, `FRONTEND_ORIGIN`은 `http://개발도메인`, `AUTH_COOKIE_SECURE=false`로 맞추고 OAuth 제공자에도 HTTP callback 주소를 등록한다.

V2 FE·BE 이미지 저장소는 `public.ecr.aws/g8x9p1p0/stockspoon-v2-frontend`와 `public.ecr.aws/g8x9p1p0/stockspoon-v2-backend`다. 각 dev CI는 해당 저장소에 전체 커밋 SHA를 이미지 태그로 push하고, 성공하면 자기 저장소의 `cd-dev` 재사용 workflow에 같은 SHA를 전달한다. BE CD는 `BE_TAG`와 `backend` 서비스만, FE CD는 `FE_TAG`와 `frontend` 서비스만 갱신한다. CD는 SSH로 `/opt/stockspoon-v2/.env`의 자기 태그만 바꾸고 EC2에 이미 수동 배치된 `docker-compose.yaml`로 해당 서비스만 pull·갱신한다. Backend 갱신 때 Compose가 필요한 MySQL도 시작한다. FE와 BE가 모두 healthy 상태가 되면 Nginx를 시작하고, 이후 앱 컨테이너가 교체되면 Nginx도 재생성해 새 컨테이너 IP를 반영한다. 이전 유효 SHA가 있으면 실패 시 대상 서비스만 되돌린다. FE·BE CD는 Cloud 저장소를 pull하거나 Compose 파일을 전송하지 않는다. 첫 배포는 각 서비스 CD가 한 번씩 성공한 뒤 전체 앱을 제공한다.

Public ECR 저장소 수에 따른 별도 요금은 없다. AWS 계정 전체의 Public ECR 이미지 저장 공간은 월 50 GB까지 무료다. 현재 계정의 기존 이미지 사용량은 확인하지 않았으므로, 총 저장량이 한도를 넘으면 초과 저장 용량이 과금될 수 있다. Public 이미지의 인터넷 전송도 인증된 다운로드 기준 월 5 TB까지 무료이고, AWS 컴퓨팅 리소스로의 전송은 무료다. 자세한 내용은 [Amazon ECR 요금](https://aws.amazon.com/ecr/pricing/)을 참고한다.

개발 DNS 레코드는 이 Terraform에서 만들지 않으며, 개발 도메인을 개발 EC2의 Elastic IP로 연결한다.

BE와 FE 저장소의 Actions **Variables**에 `AWS_V2_DEV_ECR_PUSH_ROLE_ARN`을 각각 추가한다. 값은 `terraform -chdir=app-server output -raw github_actions_v2_dev_ecr_push_role_arn`으로 가져온다. 이 OIDC 역할은 BE·FE 저장소의 dev 브랜치와 FE 저장소의 `development` Environment를 신뢰하며 두 V2 저장소에만 push 권한을 가진다. FE 저장소의 Actions **Secrets**에는 `NEXT_PUBLIC_API_BASE_URL`, `NEXT_PUBLIC_KAKAO_CLIENT_ID`, `NEXT_PUBLIC_SENTRY_DSN`, `NEXT_PUBLIC_GA_ID`, `SENTRY_AUTH_TOKEN`을 저장한다. `NEXT_PUBLIC_KAKAO_REDIRECT_URI`는 FE 이미지 빌드용이므로 FE 저장소의 `development` GitHub Environment **Variables**에 설정한다. 빌드 workflow는 이 값들을 프론트엔드 이미지에 넣으며, `NEXT_PUBLIC_*` 값은 브라우저 번들에서 공개된다. 각 저장소의 `development` GitHub Environment에는 `EC2_HOST`(개발 EC2 Elastic IP), `EC2_USER`(`ubuntu`), `EC2_SSH_KEY`(기존 EC2 키 페어 private key)를 설정한다. dev CI의 이미지 push가 성공하면 저장소 안의 `cd-dev` 재사용 workflow를 이어 호출한다. CD는 EC2의 로컬 Compose와 `.env`만 사용하며 Cloud 저장소를 clone, pull, 참조하지 않는다. 기존 main/V1 CD workflow는 그대로 둔다. EC2의 Compose 설정을 바꿨다면 사용자가 EC2에 파일을 다시 배치한다.

## SSH 접속

Apply 후 기존 Private Key로 각 서버에 접속한다.

```bash
ssh -i /path/to/stockspoon-v1-deploy.pem \
  ubuntu@$(terraform output -raw app_public_ip)

ssh -i /path/to/stockspoon-v1-deploy.pem \
  ubuntu@$(terraform output -raw k6_public_ip)
```

예시 경로를 실제 로컬 PEM 파일 경로로 변경해야 한다. Terraform에서 사용하는 EC2 Key Pair 이름은 `stockspoon-v1-deploy`다.

## 실행 전 확인 사항

- AWS 자격 증명이 올바른 계정과 리전을 가리키는지 확인한다.
- S3 상태 버킷 `stockspoon-terraform-state-v1`에 접근할 수 있어야 한다.
- `stockspoon-v1-deploy` EC2 Key Pair가 존재해야 한다.
- `ssh_allowed_cidrs`가 필요한 범위로 제한되어 있는지 확인한다.
- 기본 인스턴스 유형은 모두 `t3a.medium`이므로 예상 부하와 비용에 맞는지 확인한다.
- Plan에서 기존 VPC, Public Subnet 및 EC2의 교체나 삭제가 없는지 확인한다.

## Terraform 실행

`test-infra` 디렉터리에서 실행한다.

```bash
terraform init
terraform validate
terraform plan
terraform apply
```

`main`에 병합되면 GitHub Actions가 Plan을 다시 만든 뒤 적용한다. 로컬에서 직접 실행할 때는 Plan 결과를 먼저 검토한다.

개발 EC2의 Valkey 연결 규칙과 IAM 권한은 `redis` Terraform root가 관리한다. GitHub Actions는 `main`에 병합된 `test-infra` 변경을 적용한 뒤 `redis`와 AI 개발 root도 의존 순서대로 적용한다. 로컬에서 각 root를 직접 적용하는 경우에도 `test-infra` 다음에 `redis`를 적용해야 Valkey 접근이 완성된다.

## 주요 Output

| Output | 설명 |
| --- | --- |
| `vpc_id` | 테스트 및 개발 환경 공용 VPC ID |
| `public_subnet_id` | 기존 Public Subnet ID |
| `private_subnet_ids` | 개발 서비스가 공용으로 사용할 Private Subnet ID 목록 |
| `private_route_table_id` | 개발 Private Subnet Route Table ID |
| `app_public_ip` | 애플리케이션 EC2 Elastic IP |
| `app_private_ip` | 애플리케이션 EC2 Private IP |
| `k6_public_ip` | k6 EC2 Public IP |
| `k6_app_private_url` | k6에서 애플리케이션을 호출할 내부 URL |
| `dev_app_instance_id` | 개발 Compose EC2 ID |
| `dev_app_public_ip` | 개발 Compose EC2 Elastic IP |
| `dev_app_public_url` | HTTP 개발 앱 URL |
| `dev_app_private_ip` | 개발 Compose EC2 Private IP |
| `dev_app_private_url` | 개발 VPC 내부에서 사용할 URL |
| `dev_app_security_group_id` | 개발 EC2 전용 Security Group ID |
| `dev_app_iam_role_name` | 개발 EC2 전용 IAM Role 이름 |

Valkey와 향후 개발 서비스는 Terraform Remote State를 통해 `vpc_id`와 `private_subnet_ids`를 참조한다.
