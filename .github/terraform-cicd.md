# Terraform GitHub Actions 설정

이 저장소의 Terraform은 root별 S3 state를 그대로 사용합니다. GitHub Actions에서 새 state 버킷을 만들거나 기존 state를 옮기지 않습니다.

## 최초 1회 설정

### 1. AWS OIDC 역할 생성

`app-server` root가 기존 GitHub OIDC provider를 재사용해 다음 역할을 관리합니다.

- `stockspoon-v1-github-actions-terraform-plan`: root별 계획 생성과 state lock에 필요한 읽기 권한
- `stockspoon-v1-github-actions-terraform-apply`: 보호된 배포 환경에서 인프라를 수정하고 state를 기록하는 권한

역할을 처음 만들 때는 현재 사용 중인 AWS 자격 증명으로 한 번 적용합니다.

```bash
terraform -chdir=app-server init
terraform -chdir=app-server plan
terraform -chdir=app-server apply
```

CI apply 역할은 GitHub Actions IAM 역할·정책과 공용 OIDC provider를 수정할 수 없도록 제한되어 있습니다. 이후 이 trust나 권한을 바꾸려면 같은 `app-server` root를 로컬 AWS 자격 증명으로 적용해야 합니다.

출력된 역할 ARN을 복사합니다.

```bash
terraform -chdir=app-server output -raw github_actions_terraform_plan_role_arn
terraform -chdir=app-server output -raw github_actions_terraform_apply_role_arn
```

### 2. GitHub Actions 변수 등록

저장소의 **Settings → Secrets and variables → Actions → Variables**에 다음 변수를 추가합니다. ARN에는 비밀 값이 없으므로 Actions variable로 저장하면 됩니다.

| 변수 | 값 |
| --- | --- |
| `AWS_TERRAFORM_PLAN_ROLE_ARN` | plan 역할 ARN |
| `AWS_TERRAFORM_APPLY_ROLE_ARN` | apply 역할 ARN |

### 3. Apply 승인 환경 보호

**Settings → Environments**에서 `terraform-apply` 환경을 만들고 다음 규칙을 설정합니다.

- Required reviewers: apply를 승인할 팀원
- Deployment branches: `main`만 허용

Apply 역할의 OIDC trust policy는 이 환경 이름과 저장소 ID에 고정되어 있습니다. 환경 이름을 바꾸면 IAM trust policy와 workflow도 함께 바꿔야 합니다.

또한 **Settings → Rules → Rulesets**에서 `main`을 대상으로 ruleset을 만들고 직접 push 차단, PR 필수, 리뷰 1명 이상, force push 차단을 설정하세요. CI status check에는 워크플로에서 한 번 실행된 뒤 나타나는 `Terraform PR CI`를 지정합니다. 배포 environment 승인은 AWS apply의 추가 승인 단계입니다.

## 실행 흐름

- Terraform CI는 `main`을 대상으로 열린 모든 PR에서 실행되며, 변경된 Terraform root가 있을 때 해당 root와 remote-state 소비 root에 `fmt`, `validate`, `plan`을 실행합니다. 변경 root가 없는 PR도 고정 status check인 `Terraform PR CI`가 성공으로 완료되어 ruleset에서 사용할 수 있습니다. `dev` 대상 PR과 `dev` push는 Terraform CI/CD를 실행하지 않습니다.
- plan은 root별 PR 댓글에 리소스 추가·변경·삭제·교체 수를 남깁니다. 변경이 없는 root는 기존처럼 `변경할 리소스가 없습니다.`로 표시하고, 변경된 리소스는 펼쳐서 속성별 이전 값과 계획 값을 확인할 수 있습니다. Terraform이 민감값으로 표시한 값은 마스킹하며, 저장소가 공개이므로 민감하게 다룰 속성은 Terraform 코드에서도 `sensitive`로 지정해야 합니다. 전체 plan JSON과 바이너리 plan 파일은 댓글이나 artifact에 게시하지 않습니다.
- AWS plan 역할을 쓰는 PR plan은 저장소의 `OWNER`, `MEMBER`, `COLLABORATOR` 작성자에 한해 실행됩니다. 외부 fork PR에는 AWS 자격 증명을 주지 않고 포맷과 validate만 실행합니다.
- PR이 `main`에 병합되면 main commit의 root별 plan이 생성되고, 결과 확인 후 `terraform-apply` 환경에서 승인해야 적용 단계가 시작됩니다. `dev` 브랜치는 Terraform 배포 흐름에서 사용하지 않습니다.
- main에 Terraform root 변경이 하나라도 들어오면 8개 root 모두 plan하고 의존 순서대로 apply합니다. GitHub Actions 동시성 설정은 대기 중인 실행을 최신 실행으로 합칠 수 있으므로, 모든 root를 대상으로 해야 앞선 커밋의 변경이 빠지지 않습니다.
- Apply는 각 root를 하나씩 다시 plan하고, 그 root에서 생성한 임시 plan 파일을 즉시 apply합니다. 따라서 upstream root를 적용한 뒤 downstream root의 remote state에서 최신 output을 읽습니다. PR 및 main plan은 승인 검토용 preview이고, 실제 apply는 승인 후 현재 state 기준으로 다시 계산됩니다.

현재 root 간 적용 순서는 `shared-infra`, `test-infra`, `messaging`, `redis`, `app-server`, `ai-server/infra`, `ai-server/dev-infra`, `ai-server/dashboard`입니다. 경로 감지기는 다음 참조 관계도 반영합니다.

- `shared-infra` 변경 → `app-server`, `ai-server/infra`
- `app-server` 변경 → `ai-server/infra`
- `test-infra` 변경 → `redis`, `ai-server/dev-infra`
- `messaging` 변경 → `ai-server/dev-infra`

## S3 state 및 Terraform 버전

IAM 역할은 기존 네 버킷의 state object와 `.tflock` object만 대상으로 합니다.

- `stockspoon-terraform-state-v1`
- `stockspoon-terraform-state-ai-dev`
- `stockspoon-terraform-state-sqs`
- `stockspoon-terraform-state-redis`

새 root나 backend key를 추가하면 `app-server/terraform_github_actions.tf`의 state 경로와 IAM 권한 목록도 함께 갱신해야 합니다. 모든 root는 S3 native lockfile을 사용하므로 GitHub Actions와 local Terraform은 `1.10.0` 이상이어야 하며, workflow는 local에서 사용 중인 `1.16.2`를 고정합니다.

Apply 역할은 EC2와 ElastiCache의 쓰기 작업을 서울 리전으로 제한하고, IAM 변경은 이 Terraform root들이 사용하는 `stockspoon-v1-app-*`, `stockspoon-v1-ai-*`, `stockspoon-loadtest-*`, `stockspoon-v2-dev-*` 이름 범위로 제한합니다. GitHub Actions 역할 자체와 기존 ECR 배포 역할은 이 IAM 쓰기 범위에 포함하지 않습니다. Route 53 변경은 기존 애플리케이션 hosted zone으로 제한합니다. Lambda 함수, SQS queue, SES identity, Secrets Manager secret, ECR Public repository 변경은 저장소에서 사용하는 이름으로 제한합니다. CloudWatch와 Logs의 쓰기 작업은 서울 리전으로 제한하지만 IAM 리소스 범위는 `*`입니다.

이 apply 역할은 인프라를 수정하는 권한이므로, OIDC trust는 `main` 브랜치의 `terraform-apply` environment로 제한하고 해당 environment에서 필수 승인을 설정하세요. Plan 역할은 지정된 S3 state object 전체를 읽을 수 있으며 Secrets Manager 값 조회 API 권한은 받지 않습니다.
