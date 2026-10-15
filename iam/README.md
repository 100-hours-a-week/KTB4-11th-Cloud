# Account IAM

이 Terraform root는 AWS 콘솔에서 생성한 기존 IAM 사용자와 그룹 구성을 변경 없이 import해 관리한다.

관리 범위:

- IAM 사용자 이름, 경로, 태그
- IAM 그룹과 사용자별 그룹 멤버십
- 사용자·그룹의 Managed Policy 연결
- `terraform` 그룹의 기존 인라인 정책

의도적으로 관리하지 않는 범위:

- 콘솔 로그인 프로필과 비밀번호
- Access Key
- MFA 디바이스

따라서 import와 이후 apply는 기존 로그인, Access Key, MFA 활성화 상태를 변경하지 않는다. 사용자와 그룹에는 `prevent_destroy`를 설정해 실수로 삭제되는 것을 막는다.

## 최초 import 전 bootstrap

새 state 경로와 IAM 쓰기 권한을 GitHub Actions 역할에 먼저 반영해야 한다. 이 역할은 자기 권한을 수정할 수 없으므로 관리자 권한이 있는 로컬 AWS 자격 증명으로 `app-server`의 관련 정책을 선적용한다.

```bash
terraform -chdir=app-server init
terraform -chdir=app-server apply \
  -target=aws_iam_policy.github_actions_terraform_read \
  -target=aws_iam_role_policy.github_actions_terraform_apply_state \
  -target=aws_iam_role_policy.github_actions_terraform_apply_resources
```

그 다음 이 root를 plan한다. 최초 plan은 import만 포함해야 하며 사용자·그룹·정책의 생성, 삭제, 교체 또는 설정 변경이 있으면 적용하지 않는다.

```bash
terraform -chdir=iam init
terraform -chdir=iam plan
```

정상적인 최초 plan/apply 후 다시 실행한 plan이 `No changes`인지 확인한다. 이후 그룹 멤버십과 정책 연결을 콘솔에서 직접 수정하면 Terraform이 원래 선언 상태로 되돌리므로 코드로만 변경한다.
