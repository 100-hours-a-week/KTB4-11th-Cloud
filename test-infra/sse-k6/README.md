# SSE 전용 k6 서버

기존 `test-infra`의 VPC와 public subnet output을 읽는 독립 Terraform root입니다.
State: `s3://stockspoon-terraform-state-v1/sse-k6/terraform.tfstate`

- 기본 사양: t3a.large (2 vCPU, 8 GiB), 암호화 gp3 20 GiB
- 별도 EC2, SG, IAM role/profile을 관리합니다.
- 일반 k6와 기존 테스트와 같은 버전의 SSE 확장 바이너리(`/usr/local/bin/k6-sse`)를 설치합니다.
- bootstrap은 이 디렉토리 안의 파일만 사용합니다.
- 운영 SSE 사설 IP 접근을 위한 라우팅이나 대상 SG 변경은 포함하지 않습니다.
- SSH 허용 CIDR 기본값은 기존 테스트 서버와 같은 `0.0.0.0/0`이며 `ssh_allowed_cidrs`로 제한할 수 있습니다.

검토 명령어:

```sh
terraform -chdir=test-infra/sse-k6 init
terraform -chdir=test-infra/sse-k6 plan
```

실제 생성은 별도 승인 후 apply합니다. 이전 test-infra plan 파일은 사용하지 않습니다.
