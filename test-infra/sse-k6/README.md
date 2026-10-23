# SSE 전용 k6 서버

기존 `test-infra`의 VPC와 public subnet output을 읽는 독립 Terraform root입니다.
State: `s3://stockspoon-terraform-state-v1/sse-k6/terraform.tfstate`

- 기본 사양: t3a.large (2 vCPU, 8 GiB), 암호화 gp3 20 GiB
- 별도 EC2, SG, IAM role/profile을 관리합니다.
- 일반 k6와 기존 테스트와 같은 버전의 SSE 확장 바이너리(`/usr/local/bin/k6-sse`)를 설치합니다.
- bootstrap은 이 디렉토리 안의 파일만 사용합니다.
- 기존 VPC 피어링을 재사용해 운영 private subnet으로 향하는 경로와 k6 사설 IP `/32` 반환 경로를 추가합니다.
- 운영 market-http SG에서 전용 k6 SG의 TCP 8000 접근만 허용합니다. 피어링 자체와 기존 관측 경로는 변경하지 않습니다.
- CD 적용 후 `http://<SSE 태스크 사설 IP>:8000/market/prices/stream?codes=000660`으로 접속합니다. 태스크 교체 시 IP를 다시 조회해야 합니다.
- SSH 허용 CIDR 기본값은 기존 테스트 서버와 같은 `0.0.0.0/0`이며 `ssh_allowed_cidrs`로 제한할 수 있습니다.

검토 명령어:

```sh
terraform -chdir=test-infra/sse-k6 init
terraform -chdir=test-infra/sse-k6 plan
```

실제 생성은 별도 승인 후 apply합니다. 이전 test-infra plan 파일은 사용하지 않습니다.
