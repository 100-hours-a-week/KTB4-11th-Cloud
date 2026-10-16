# Terraform CI 쓰기 정책 분리

기존 resource-write 인라인 정책을 4개의 고객 관리형 정책으로 나눈다. state-write 인라인 정책과 기존 read/state-access 관리형 정책은 유지한다.

| 정책 접미사 | 범위 | 소스 |
|---|---|---|
| compute | EC2·ElastiCache·ECS·ASG·Application Auto Scaling·ALB·ACM | `terraform_ci_write_compute.tf` |
| application | S3·Lambda·Secrets Manager·SQS·ECR·SES·Route 53 | `terraform_ci_write_application.tf` |
| observability | CloudWatch·Logs | `terraform_ci_write_observability.tf` |
| identity | IAM 리소스·PassRole·서비스 연결 역할 | `terraform_ci_write_identity.tf` |

관리형 정책 이름은 `stockspoon-v1-github-actions-terraform-write-<접미사>`다. 각 정책의 JSON 크기를 plan에서 6,144자 이하로 검사한다. 기존 Action·Resource·Condition은 유지하며, 새 서비스 권한은 추가하지 않는다. EventBridge와 Logs resource policy 권한은 후속 CloudWatch 관측 변경에서 추가한다.

## 로컬 적용 자격 증명

CI 역할은 자기 자신의 권한을 수정할 수 없으므로 이 변경은 로컬에서 먼저 적용해야 한다. `pattie_for_terraform`의 현재 정책 시뮬레이션에서는 `iam:CreatePolicy`, `iam:AttachRolePolicy`, `iam:DeleteRolePolicy`가 거부됐다. 현재 자격 증명으로 apply를 반복하지 않는다.

관리자는 아래 작업을 필요한 대상에 한정해 허용해야 한다.

- 새 `stockspoon-v1-github-actions-terraform-write-*` 정책: CreatePolicy, CreatePolicyVersion, SetDefaultPolicyVersion, DeletePolicyVersion 등 정책 수명주기 권한
- `stockspoon-v1-github-actions-terraform-apply` 역할: AttachRolePolicy, DetachRolePolicy. `iam:PolicyARN` 조건을 새 정책 ARN 접두사로 제한
- 전환 2단계에서 같은 역할의 기존 resource-write 인라인 정책을 제거할 DeleteRolePolicy 권한
- Terraform refresh에 필요한 Get/List 권한

관리형 정책을 연결할 수 있는 개수의 여유도 적용 전에 확인한다. AWS가 허용하지 않은 권한을 다른 프로필이나 CI로 우회해 적용하지 않는다.

## 1단계: 관리형 정책 연결

`retain_legacy_terraform_ci_write_policy=true`가 기본값이다. 새 정책 4개와 연결 4개를 추가하면서 기존 인라인 권한을 유지한다. `moved` 블록은 기존 인라인 리소스를 `[0]` 주소로 연결해 재생성하지 않는다.

```bash
AWS_PROFILE=pattie_for_terraform terraform -chdir=app-server plan \
  -target=aws_iam_policy.github_actions_terraform_read \
  -target=aws_iam_role_policy_attachment.terraform_ci_write \
  -target=aws_iam_role_policy.github_actions_terraform_apply_resources \
  -out=/tmp/ci-policy-phase1.tfplan
AWS_PROFILE=pattie_for_terraform terraform -chdir=app-server apply /tmp/ci-policy-phase1.tfplan
```

계획에 새 정책 4개·연결 4개가 있으며 삭제가 없는지 확인한다. 기존 read 및 인라인 정책의 갱신은 포함될 수 있다. 기존 인라인 정책은 전환 기간 동안 Sid를 제거한 동일 권한으로 유지한다.

연결 상태를 조회한다.

```bash
aws iam list-attached-role-policies --profile pattie_for_terraform \
  --role-name stockspoon-v1-github-actions-terraform-apply
```

새 관리형 정책 4개의 연결, 기존 권한과의 의미상 동등성, CI plan·apply 정상 동작을 확인한다. 인라인 권한을 유지하는 동안의 CI 성공만으로 새 관리형 정책의 권한 동등성이 증명되는 것은 아니다.

## 2단계: 기존 인라인 쓰기 정책 제거

4개 연결 확인 후 `variables.tf`의 `retain_legacy_terraform_ci_write_policy` 기본값을 `false`로 변경해 커밋한다. 일회성 `-var=false`만 사용하면 다음 CI apply가 기본값 true로 복원하므로 사용하지 않는다.

같은 target으로 새 plan을 만들고, 관리형 정책·연결이 모두 유지된 채 기존 resource-write 인라인 정책 1개만 삭제되는지 확인한 뒤 적용한다. state-write 정책은 삭제하지 않는다. 이후 CI 권한을 다시 확인한다.

전환 2단계를 실행하기 전까지 기본값 true를 유지한다. 아직 연결되지 않은 상태에서 false로 바꾸거나 기존 인라인 정책을 직접 먼저 삭제하지 않는다.
