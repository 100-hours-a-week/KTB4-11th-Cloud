# Terraform CI 쓰기 정책 분리

기존 resource-write 인라인 정책을 4개의 고객 관리형 정책으로 나눈다. state-write 인라인 정책과 기존 read/state-access 관리형 정책은 유지한다.

2026-10-16 운영 역할의 관리형 정책 4개 연결과 기존 resource-write 제거를 완료했다. 현재 `retain_legacy_terraform_ci_write_policy` 기본값은 `false`다. 아래 2단계 절차는 기존 인라인 정책이 남아 있는 환경을 전환할 때 사용한다.

| 정책 접미사 | 범위 | 소스 |
|---|---|---|
| compute | EC2·ElastiCache·ECS·ASG·Application Auto Scaling·ALB·ACM | `modules/terraform-ci-policies/compute.tf` |
| application | S3·Lambda·Secrets Manager·SQS·ECR·SES·Route 53 | `modules/terraform-ci-policies/application.tf` |
| observability | CloudWatch·Logs·EventBridge | `modules/terraform-ci-policies/observability.tf` |
| identity | IAM 리소스·PassRole·서비스 연결 역할 | `modules/terraform-ci-policies/identity.tf` |

정책 문서 정의는 저장소 최상위 `modules/terraform-ci-policies/` 공용 모듈에 모은다. `app-server`에서는 `../modules/terraform-ci-policies`로 참조한다. 루트에서 ARN 범위를 전달하고 생성된 JSON을 받는다. 실제 IAM 정책·연결 리소스는 `app-server` 루트와 기존 state에 유지하므로 폴더 정리로 AWS 리소스 주소가 바뀌지 않는다. 공용 모듈 변경은 CI 영향 범위 감지에서 `app-server`와 기존 remote-state 의존 root로 전파된다.

관리형 정책 이름은 `stockspoon-v1-github-actions-terraform-write-<접미사>`다. 각 정책의 JSON 크기를 plan에서 6,144자 이하로 검사한다. 기존 Action·Resource·Condition은 유지하며, 이번 CloudWatch 관측에 필요한 Logs resource policy·EventBridge 권한만 추가한다.

## 로컬 적용 자격 증명

CI 역할은 자기 자신의 권한을 수정할 수 없으므로 이 변경은 로컬에서 먼저 적용해야 한다. `pattie_for_terraform`의 현재 정책 시뮬레이션에서는 `iam:CreatePolicy`, `iam:AttachRolePolicy`, `iam:DeleteRolePolicy`가 거부됐다. 이 권한이 없는 프로필로 apply를 반복하지 않는다. 운영 전환은 사용자가 지정한 관리자 프로필 `stockspoon`으로 수행했다.

관리자는 아래 작업을 필요한 대상에 한정해 허용해야 한다.

- 새 `stockspoon-v1-github-actions-terraform-write-*` 정책: CreatePolicy, CreatePolicyVersion, SetDefaultPolicyVersion, DeletePolicyVersion 등 정책 수명주기 권한
- `stockspoon-v1-github-actions-terraform-apply` 역할: AttachRolePolicy, DetachRolePolicy. `iam:PolicyARN` 조건을 새 정책 ARN 접두사로 제한
- 전환 2단계에서 같은 역할의 기존 resource-write 인라인 정책을 제거할 DeleteRolePolicy 권한
- Terraform refresh에 필요한 Get/List 권한

관리형 정책을 연결할 수 있는 개수의 여유도 적용 전에 확인한다. AWS가 허용하지 않은 권한을 다른 프로필이나 CI로 우회해 적용하지 않는다.

## 1단계: 관리형 정책 연결

기존 인라인 정책이 남아 있는 환경의 최초 전환에서는 `retain_legacy_terraform_ci_write_policy` 기본값을 임시로 `true`로 설정한다. 새 정책 4개와 연결 4개를 추가하면서 기존 인라인 권한을 유지한다. `moved` 블록은 기존 인라인 리소스를 `[0]` 주소로 연결해 재생성하지 않는다.

```bash
AWS_PROFILE=stockspoon terraform -chdir=app-server plan \
  -target=aws_iam_policy.github_actions_terraform_read \
  -target=aws_iam_role_policy_attachment.terraform_ci_write \
  -target=aws_iam_role_policy.github_actions_terraform_apply_resources \
  -out=/tmp/ci-policy-phase1.tfplan
AWS_PROFILE=stockspoon terraform -chdir=app-server apply /tmp/ci-policy-phase1.tfplan
```

계획에 새 정책 4개·연결 4개가 있으며 삭제가 없는지 확인한다. 기존 read 및 인라인 정책의 갱신은 포함될 수 있다. 기존 인라인 정책은 전환 기간 동안 Sid를 제거한 동일 권한으로 유지한다.

연결 상태를 조회한다.

```bash
aws iam list-attached-role-policies --profile stockspoon \
  --role-name stockspoon-v1-github-actions-terraform-apply
```

새 관리형 정책 4개의 연결, 기존 권한과의 의미상 동등성, CI plan·apply 정상 동작을 확인한다. 인라인 권한을 유지하는 동안의 CI 성공만으로 새 관리형 정책의 권한 동등성이 증명되는 것은 아니다.

## 2단계: 기존 인라인 쓰기 정책 제거

4개 연결 확인 후 `variables.tf`의 `retain_legacy_terraform_ci_write_policy` 기본값을 `false`로 변경해 커밋한다. 일회성 `-var=false`만 사용하고 코드 기본값을 true로 남기면 다음 CI apply가 인라인 정책을 복원하므로 코드도 함께 변경한다.

같은 target으로 새 plan을 만들고, 관리형 정책·연결이 모두 유지된 채 기존 resource-write 인라인 정책 1개만 삭제되는지 확인한 뒤 적용한다. state-write 정책은 삭제하지 않는다. 이후 CI 권한을 다시 확인한다.

전환 2단계를 실행하기 전까지 기본값 true를 유지한다. 아직 연결되지 않은 상태에서 false로 바꾸거나 기존 인라인 정책을 직접 먼저 삭제하지 않는다.
