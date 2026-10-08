# StockSpoon V2 개발 환경 Valkey 인프라

이 디렉터리는 Amazon ElastiCache Serverless for Valkey 개발 환경을 관리하는 Terraform Root다.

현재 2단계에서는 Terraform Backend, Provider, 공통 변수와 태그, 기존 인프라 Remote State 연결만 구성한다. Private Subnet, Security Group, Valkey, IAM Policy와 CloudWatch Alarm은 이후 단계에서 추가한다.

## 참조하는 기존 인프라

### test-infra

- 상태 버킷: `stockspoon-terraform-state-v1`
- 상태 Key: `test-infra/terraform.tfstate`
- 사용 Output: `vpc_id`
- 목적: Valkey를 배치할 개발 VPC 참조

### AI 개발 서버

- 소스 디렉터리: `ai-server/dev-infra`
- 소스 브랜치: `feat/42-ai-dev-ec2`
- 상태 버킷: `stockspoon-terraform-state-ai-dev`
- 상태 Key: `ai-server/dev-infra/terraform.tfstate`
- 사용 Output: `ai_security_group_id`, `ai_iam_role_arn`
- 목적: Valkey 네트워크 접근과 IAM 접속 권한 연결 대상 참조

`ai-server/dev-infra`는 현재 Redis 작업 브랜치에 아직 병합되지 않았다. 해당 브랜치가 기준 브랜치에 병합된 뒤 다음 단계의 리소스 연결을 진행한다.

### 향후 Backend 개발 서버

Valkey는 App 서버의 Backend에서 사용한다. 현재 Backend 개발 EC2와 전용 Security Group, IAM Role은 아직 생성되지 않았다.

Redis Terraform에서는 다음 항목만 미리 생성한다.

- Backend용 ElastiCache IAM 인증 사용자
- Backend용 `elasticache:Connect` IAM Policy
- 향후 연결에 사용할 IAM Policy ARN Output

기존 `stockspoon-loadtest-app`은 Backend 개발 서버로 간주하지 않으며 Valkey 접근 권한을 부여하지 않는다. Backend 서버를 구축할 때 해당 인프라에서 IAM Role과 Instance Profile을 만들고 Redis가 출력한 Policy ARN을 연결한다. Backend Security Group이 생긴 뒤 Valkey `6379` 인바운드 규칙도 추가한다.

## Terraform 상태

Redis 상태는 SQS와 동일한 버킷 이름 형식으로 분리한다.

- 버킷: `stockspoon-terraform-state-redis`
- Key: `redis/dev/terraform.tfstate`
- 리전: `ap-northeast-2`
- Locking: S3 Lockfile
- 암호화: 활성화

이 버킷은 아직 생성되지 않았다. `terraform init` 전에 SQS 상태 버킷과 동일하게 Versioning, AES256 기본 암호화, Public Access Block을 적용해 별도로 준비해야 한다.

## 로컬 정적 검사

Remote Backend에 연결하지 않고 구성 문법만 확인할 때 사용한다.

```bash
terraform -chdir=redis fmt -check -recursive
terraform -chdir=redis init -backend=false
terraform -chdir=redis validate
```

## 개발 환경 초기화와 Plan

상태 버킷을 준비한 후 다음 명령을 사용한다.

```bash
terraform -chdir=redis init \
  -reconfigure \
  -backend-config=environments/dev/backend.hcl

terraform -chdir=redis plan \
  -var-file=environments/dev/terraform.tfvars.example
```

현재 단계에서는 생성할 AWS 리소스가 없으며 `terraform apply`를 실행하지 않는다. 이후 리소스가 추가되더라도 Plan에서 기존 인프라의 변경이나 삭제가 없는지 먼저 확인한다.
