# Repman 자격 증명 운영

Repman Fargate 작업은 DB 감시 계정, 복제 계정, API 계정, ProxySQL 관리자 계정의 비밀번호를 SSM Parameter Store에 저장된 값으로 전달받아 환경 변수로 사용한다. 시작할 때 이 값을 Repman 설정 파일(TOML)에 넣으며, 비밀 값은 코드나 로그에 기록하지 않는다.

## 자격 증명의 기준 저장소

Repman 설정은 `monitoring-secret-versioning = false`를 사용한다. Repman은 기본 설정에서 EFS의 `secret_store.json`에 남아 있는 자격 증명 버전을 설정 파일보다 먼저 사용할 수 있다. 오래된 값이 남아 있으면 ECS 작업이 새 SSM 값을 전달받더라도 Repman은 이전 비밀번호로 DB에 접속해 `ErrorAuth`를 보고할 수 있다.

Terraform으로 관리하는 이 서비스에서는 시작할 때 전달된 SSM 값이 자격 증명의 기준이다. EFS는 계속 연결해 Repman의 다른 데이터와 인증서 상태를 보존한다.

이 설정에서는 Repman 화면이나 API에서 자격 증명을 직접 변경하지 않는다. 운영 중 자격 증명을 바꿀 때는 SSM 값을 갱신한 뒤 ECS 작업을 다시 배포한다. SSM Parameter 값만 바꾸면 이미 실행 중인 ECS 작업의 환경 변수는 갱신되지 않는다.

## SSM 값 변경 절차

1. 승인된 절차에 따라 해당 SSM `SecureString` 값을 변경한다. 비밀번호를 Terraform 변수, 셸 명령 기록, PR 또는 로그에 넣지 않는다.
2. Repman 서비스에 새 작업 배포를 요청해 ECS가 최신 SSM 값을 가져오도록 한다. 작업 정의는 SSM 파라미터의 ARN을 참조하므로, 값만 변경하면 Terraform 계획에 작업 정의 변경이 나타나지 않을 수 있다.
3. Repman API에서 연결된 DB의 역할과 경고를 확인한다. 두 DB의 역할이 예상과 일치하고 `ErrorAuth`가 없어야 한다.
4. 복제 자격 증명을 변경했다면 계획된 전환 절차를 통해 새 계정이 승격 및 재연결 과정에서 정상적으로 작동하는지 확인한다.

아래는 재배포 명령 예시다. 실행 전에 실제 계정, 리전, 클러스터와 서비스 이름을 확인한다.

```bash
aws ecs update-service \
  --cluster <ecs-cluster> \
  --service <repman-service> \
  --force-new-deployment \
  --region <aws-region>
```

재배포한 뒤에도 인증 오류가 남아 있으면 FIS 장애 주입을 시작하지 않는다. DB 계정이나 EFS의 `secret_store.json`을 임의로 변경하지 말고, 작업에 전달된 SSM 파라미터 버전과 Repman이 실제로 사용하는 설정을 비교한다.
