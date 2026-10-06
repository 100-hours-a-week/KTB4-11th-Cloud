# Shared infrastructure

애플리케이션 서버와 AI 서버가 함께 사용하는 VPC, public subnet, internet gateway, route table을 관리합니다.

S3의 `shared-infra/terraform.tfstate`에는 기존 네트워크 6개가 이미 import되어 있습니다. 기존 `infra`와 `ai-server/infra`의 remote state 참조 전환이 끝나기 전에는 어느 Terraform root에도 `apply`하지 않습니다.
