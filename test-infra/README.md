# 테스트 및 개발 인프라

이 디렉터리는 부하 테스트용 VPC와 EC2 인스턴스 두 대를 관리한다. 같은 VPC를 StockSpoon V2 개발 환경의 공용 네트워크로도 사용한다.

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

애플리케이션 EC2는 HTTP와 HTTPS 요청을 외부에서 받을 수 있다. SSH는 기본적으로 `0.0.0.0/0`에서 허용되므로, 필요한 경우 로컬 `terraform.tfvars`의 `ssh_allowed_cidrs`를 접속할 공인 IP의 `/32` CIDR로 제한한다.

### 로그 및 모니터링

- 애플리케이션 EC2에서 기존 StockSpoon 애플리케이션 CloudWatch Log Group에 로그 기록
- 애플리케이션 및 k6 서버용 CloudWatch Agent IAM 권한
- 보존 기간이 14일인 테스트 시스템 Log Group

CloudWatch Agent 수동 설치 방법은 [CLOUDWATCH_AGENT.md](CLOUDWATCH_AGENT.md), 공통 설정은 [cloudwatch-agent.json](cloudwatch-agent.json)을 참고한다.

## 애플리케이션 초기화 범위

애플리케이션 EC2의 Bootstrap은 기존 인프라와 동일한 Docker 배포 환경까지만 준비한다. 애플리케이션 컨테이너를 자동으로 실행하거나 비밀 값을 주입하지 않는다.

인프라 구축 후 테스트 서버의 `.env`를 설정하고 기존 배포 절차를 통해 필요한 Frontend 및 Backend 이미지를 배포한다.

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

`terraform apply`는 Plan 결과를 검토한 후 사용자가 직접 실행한다.

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

Valkey와 향후 개발 서비스는 Terraform Remote State를 통해 `vpc_id`와 `private_subnet_ids`를 참조한다.
