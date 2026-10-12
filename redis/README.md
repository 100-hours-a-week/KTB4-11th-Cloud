# StockSpoon V2 개발 환경 Valkey 인프라

이 디렉터리는 Amazon ElastiCache Serverless for Valkey 개발 환경을 관리하는 Terraform Root다.

현재 5단계까지 Terraform Backend, 기존 인프라 Remote State, Valkey Security Group, IAM 인증, Serverless Cache와 Discord 장애 알림을 구성한다. Private Subnet과 Route Table은 `test-infra`가 소유하며 Redis는 해당 Output을 참조한다. 개발 Backend와 개발 AI 서버는 공용 IAM 사용자로 Valkey에 접근한다.

## 참조하는 기존 인프라

### test-infra

- 상태 버킷: `stockspoon-terraform-state-v1`
- 상태 Key: `test-infra/terraform.tfstate`
- 사용 Output: `vpc_id`, `private_subnet_ids`, `dev_app_security_group_id`, `dev_app_iam_role_name`
- 목적: Valkey 네트워크와 개발 Backend 접근 권한 구성

### Backend 개발 서버

Valkey는 test-infra의 개발 애플리케이션 EC2에서 실행되는 Backend가 사용한다. 개발 EC2는 기존 loadtest 애플리케이션과 분리된 전용 Security Group과 IAM Role을 사용한다.

Redis Terraform은 test-infra의 `dev_app_security_group_id` Output으로 식별한 개발 Security Group에서만 Valkey TCP 6379 포트를 허용하고, `dev_app_iam_role_name` Output의 EC2 Role에 Backend용 IAM Policy를 연결한다.

Valkey 접근에는 IAM 인증을 사용한다. 공용 Policy는 해당 Valkey Cache와 애플리케이션용 ElastiCache User ARN의 `elasticache:Connect`만 허용한다.

### AI 개발 서버

Redis Terraform은 `ai-server/dev-infra` Remote State에서 개발 AI Security Group과 IAM Role을 참조한다. Valkey Security Group은 AI Security Group에서 오는 TLS TCP `6379`를 허용하고, AI EC2 Role에는 공용 애플리케이션 User와 Cache에 대한 `elasticache:Connect` Policy를 연결한다.

개발 편의를 위해 Backend와 AI는 같은 IAM User를 사용하고 모든 Key·채널과 일반 명령에 접근할 수 있다. `@dangerous` 범주의 명령은 차단한다.

## 네트워크 구성

Valkey는 `test-infra` VPC 안의 공용 개발 Private Subnet 두 개를 사용한다. Subnet과 Route Table은 `test-infra` Terraform State가 관리하고 Redis는 `private_subnet_ids` Output을 Remote State로 참조한다.

| 이름 | CIDR | 가용 영역 | Public IP 자동 할당 |
| --- | --- | --- | --- |
| `stockspoon-loadtest-private-a` | `10.20.10.0/24` | `ap-northeast-2a` | 비활성화 |
| `stockspoon-loadtest-private-c` | `10.20.11.0/24` | `ap-northeast-2c` | 비활성화 |

두 Subnet은 `test-infra`의 별도 Private Route Table에 연결한다. Route Table에는 AWS가 자동으로 만드는 VPC `local` 경로만 존재하며 Internet Gateway와 NAT Gateway 경로를 추가하지 않는다. 기존 Public Subnet, Route Table, EC2 Network Interface는 수정하지 않는다.

Valkey Security Group은 test-infra의 개발 전용 앱 Security Group과 개발 AI Security Group에서 오는 TCP `6379`만 허용한다. `0.0.0.0/0`, loadtest 앱 및 개발자 개인 IP에는 열지 않는다.

## Terraform 상태

Redis 상태는 SQS와 동일한 버킷 이름 형식으로 분리한다.

- 버킷: `stockspoon-terraform-state-redis`
- Key: `redis/dev/terraform.tfstate`
- 리전: `ap-northeast-2`
- Locking: S3 Lockfile
- 암호화: 활성화

버킷에는 SQS 상태 버킷과 동일하게 Versioning, AES256 기본 암호화, Public Access Block이 적용되어 있다. `redis/environments/dev/backend.hcl`을 사용해 Remote Backend 초기화를 완료했다.

## Valkey Serverless 구성

| 항목 | 값 |
| --- | --- |
| Cache 이름 | `stockspoon-v2-dev-valkey` |
| Engine | Valkey 8 |
| Network | IPv4, Private Subnet 2개 |
| TLS | 필수 |
| 인증 | IAM 기반 RBAC |
| 최대 저장 용량 | 1GB |
| 최대 처리량 | 1,000 ECPU/초 |
| Snapshot | 개발 환경에서는 비활성화 |

Valkey User Group에는 비밀번호 사용자를 넣지 않고 개발 애플리케이션 공용 IAM 인증 사용자 한 명을 포함한다.

| 사용자 | 허용 범위 |
| --- | --- |
| Backend·AI 공용 | 모든 Key·채널과 일반 명령 (`@dangerous` 제외) |

공용 사용자는 읽기, 쓰기, Pub/Sub, 연결 및 Cluster 토폴로지 조회가 가능하다. 운영에 위험한 명령은 제외한다.

Valkey Serverless에서는 `PSUBSCRIBE`와 `PUNSUBSCRIBE`를 지원하지 않는다. 구독자는 필요한 채널을 `SUBSCRIBE`로 개별 구독하거나 애플리케이션 구조에 맞춰 Sharded Pub/Sub 사용 여부를 검토해야 한다.

## IAM Policy 연결

Redis Terraform은 공용 Managed Policy를 생성해 개발 Backend와 AI의 EC2 Role에 연결한다.

- `stockspoon-v2-dev-valkey-backend-connect` (기존 이름을 유지하며 Backend·AI가 공용으로 사용)

Policy는 `elasticache:Connect`를 해당 Cache ARN과 공용 ElastiCache User ARN으로 제한한다. Terraform Output에도 사용자 이름과 Policy ARN을 제공한다.

## 모니터링 및 Discord 알림

별도 CloudWatch Dashboard는 생성하지 않는다. 다음 세 CloudWatch Alarm만 구성한다.

| 경보 | 1분 기준 | 누락 데이터 |
| --- | ---: | --- |
| 저장 용량 | 1GB 상한의 75%인 `805,306,368 bytes` 이상 | 정상 처리 |
| ECPU | 1,000 ECPU/초 상한의 75%인 `45,000 ECPU/분` 이상 | 정상 처리 |
| 명령 제한 | `ThrottledCmds` 합계 1개 이상 | 정상 처리 |

Serverless Cache의 CloudWatch Dimension은 `clusterId=stockspoon-v2-dev-valkey`를 사용한다. 세 경보 모두 `ALARM` Action만 설정하며 `ok_actions`는 설정하지 않는다.

Valkey 전용 Lambda `stockspoon-v2-dev-valkey-discord-notifier`가 경보를 기존 Discord 채널로 전달한다. Lambda 내부에서도 `ALARM` 상태가 아닌 이벤트는 무시한다.

Terraform은 Valkey 전용 빈 Secrets Manager Secret `stockspoon/v2/dev/valkey/discord-webhook`을 생성한다. Webhook URL 값은 Terraform 코드나 State에 저장하지 않는다. Apply 후 사용자가 Secrets Manager에서 같은 Discord 채널의 Webhook URL을 직접 입력하고, Lambda는 실행 시 `secretsmanager:GetSecretValue`로 값을 읽는다.

알림 Lambda의 CloudWatch Log Group 보존 기간은 14일이다.
