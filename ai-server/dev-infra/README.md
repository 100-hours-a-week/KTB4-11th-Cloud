# AI 개발 서버 인프라

StockSpoon V2 AI 서버의 개발 환경을 구성하는 Terraform 루트 모듈이다. 기존 `test-infra`의 네트워크를 함께 사용하고, `messaging/dev`에서 만든 SQS 큐와 AI 전용 IAM 정책을 연결한다.

이 디렉터리는 `test-infra`나 `messaging`과 별도의 Terraform state를 사용한다. 따라서 여기서 `apply`해도 기존 VPC나 SQS를 새로 만들거나 직접 수정하지 않는다.

## 참조 구조

여기서 말하는 참조는 `terraform import`가 아니다. 다른 Terraform state가 공개한 output을 `terraform_remote_state`로 읽고, output에 없는 보안 그룹은 AWS data source로 조회한다.

| 참조 대상 | state 또는 조회 기준 | 가져오는 값 | 사용 위치 |
| --- | --- | --- | --- |
| `test-infra/network.tf`, `test-infra/outputs.tf` | `s3://stockspoon-terraform-state-v1/test-infra/terraform.tfstate` | `vpc_id`, `public_subnet_id` | EC2와 AI 보안 그룹을 기존 테스트 VPC·퍼블릭 서브넷에 배치 |
| `test-infra/security_group.tf`에서 생성한 앱 보안 그룹 | 이름 `stockspoon-loadtest-app-sg`와 위 VPC ID로 AWS 조회 | 보안 그룹 ID | 테스트 앱 서버에서 AI API의 TCP 8000 포트로 접근 허용 |
| `messaging/dev` | `s3://stockspoon-terraform-state-sqs/messaging/dev/terraform.tfstate` | `ai_sqs_policy_arn`, `report_queue_url`, `order_queue_url` | EC2 Role에 AI SQS 정책 연결, 인스턴스 환경 파일에 Queue URL 기록 |

`messaging/dev` 소스는 PR #41에서 추가되는 구성이다. 현재 브랜치에 해당 소스 디렉터리가 보이지 않더라도 이미 배포된 S3 remote state가 있으므로 이 구성에서는 output을 읽을 수 있다. 최종 병합 후에는 `messaging/dev`가 SQS 정책과 Queue URL의 원본 관리 위치가 된다.

2026-10-08 배포 시 확인된 네트워크 값은 다음과 같다.

- VPC: `vpc-0e2bb0f9afe76813f`
- 퍼블릭 서브넷: `subnet-04b4bdc2429eb99c2`
- 호출을 허용한 테스트 앱 보안 그룹: `sg-05130de1f21731b00`

다음 AWS 리소스도 이미 존재한다는 전제로 사용한다. 이 리소스들은 이 Terraform state로 가져오거나 소유하지 않는다.

- EC2 Key Pair: `stockspoon-v1-deploy`
- Tailscale 인증 키가 저장된 SSM SecureString: `/stockspoon/ai/tailscale-auth-key`
- Ubuntu AMI: `ami-0ebb55ce78339fc0c`

## 생성하는 리소스

- `t3a.medium` EC2 1대
- 암호화된 30 GiB gp3 루트 볼륨
- 고정 공인 IP용 Elastic IP 1개와 EC2 연결
- AI 서버 전용 보안 그룹
- EC2 IAM Role과 Instance Profile
- Tailscale SSM 파라미터 조회 정책
- CloudWatch 로그·메트릭 전송 정책
- CloudWatch Logs 그룹 4개
  - `/stockspoon/v2/dev/ai/system`: 14일 보관
  - `/stockspoon/v2/dev/ai/application`: 30일 보관
  - `/stockspoon/v2/dev/ai/postgres`: 30일 보관
  - `/stockspoon/v2/dev/ai/questdb`: 30일 보관

Terraform state는 아래의 별도 S3 경로에 저장한다.

```text
s3://stockspoon-terraform-state-ai-dev/ai-server/dev-infra/terraform.tfstate
```

## 네트워크와 접근 제어

- AI API의 TCP 8000 포트는 `stockspoon-loadtest-app-sg`가 연결된 리소스에서만 접근할 수 있다.
- `ssh_allowed_cidrs` 기본값이 빈 목록이므로 인터넷에서 들어오는 SSH 규칙은 생성되지 않는다.
- 서버 관리는 기본적으로 AWS Systems Manager Session Manager 또는 Tailscale을 사용한다.
- EC2의 외부 통신은 SQS, SSM, Tailscale 설치와 패키지 다운로드를 위해 전체 허용되어 있다.
- EC2 Instance Metadata Service는 IMDSv2 토큰을 반드시 사용하도록 설정한다.
- 애플리케이션에는 Access Key를 저장하지 않는다. EC2 Instance Profile의 임시 자격 증명을 사용한다.

## EC2 초기 설정

최초 부팅 시 `templates/user-data.sh`가 다음 작업을 수행한다.

1. Docker, Docker Compose, AWS CLI를 설치한다.
2. CloudWatch Agent를 설치하고 `config/cloudwatch-agent.json` 설정으로 실행한다.
3. SSH 비밀번호 로그인과 root 로그인을 차단한다.
4. `/etc/stockspoon/ai.env`에 AWS 리전과 개발용 SQS Queue URL을 기록한다.
5. EC2 Role 권한으로 SSM Parameter Store에서 Tailscale 인증 키를 읽는다.
6. Tailscale을 설치하고 호스트 이름 `stockspoon-v2-dev-ai`로 연결한다.

`config/cloudwatch-agent.json`은 base64로 인코딩되어 user data에 전달된다. 부팅 과정에서 `/opt/aws/amazon-cloudwatch-agent/etc/stockspoon-ai-dev-cloudwatch-agent.json`으로 저장되며, Agent가 시스템 로그와 호스트 메트릭을 CloudWatch로 전송한다. 대시보드는 생성하지 않는다.

## SQS 권한

`messaging/dev`가 출력한 `stockspoon-v2-dev-ai-sqs` 정책을 EC2 Role에 연결한다. 이 정책의 실제 허용 작업과 큐 범위는 `messaging/dev`에서 관리한다. 이 디렉터리는 해당 정책을 복제하지 않고 ARN만 참조한다.

Queue URL은 다음 경로에 기록된다.

```text
/etc/stockspoon/ai.env
```

Queue URL은 인증 정보가 아니며, 실제 SQS 호출 권한은 EC2 Role과 연결된 IAM 정책으로 제어한다.

## CloudWatch Agent 적용 상태

2026-10-08 기준 현재 EC2에도 SSM Run Command로 같은 설정을 적용했다. Agent 서비스는 `enabled`, `active` 상태다.

- 로그 스트림: `/stockspoon/v2/dev/ai/system`의 `i-01a64c0fbc3521618`
- 메트릭 네임스페이스: `AI_DEV_CWAgent`
- 확인된 메트릭: `mem_used_percent`, `mem_available_percent`, `disk_used_percent`

## 변경 및 삭제 시 주의 사항

EC2에는 실수로 서버가 교체되거나 삭제되는 일을 막기 위해 `prevent_destroy = true`가 설정되어 있다. AMI, 서브넷 등 EC2 교체가 필요한 값을 변경하거나 전체 인프라를 제거하려면 먼저 영향 범위를 확인한 후 이 보호 설정을 의도적으로 조정해야 한다.

또한 `user_data` 변경은 현재 `ignore_changes` 대상이다. 스크립트를 수정해도 이미 생성된 EC2에 자동 반영되지 않으므로, 필요한 변경은 SSM으로 적용하거나 교체 절차를 별도로 계획한다.
