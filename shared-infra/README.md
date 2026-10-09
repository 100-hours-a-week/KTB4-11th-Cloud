# Shared infrastructure

애플리케이션 서버와 AI 서버가 함께 사용하는 VPC, public subnet, internet gateway, route table을 관리합니다.

S3의 `shared-infra/terraform.tfstate`에는 기존 네트워크 6개가 이미 import되어 있습니다. `app-server`와 `ai-server/infra`는 이 state의 VPC와 subnet output을 참조합니다.
