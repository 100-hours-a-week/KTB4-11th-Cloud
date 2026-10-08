# Valkey는 test-infra가 관리하는 VPC를 재사용합니다.
data "terraform_remote_state" "test" {
  backend = "s3"

  config = {
    bucket = var.test_infra_state_bucket
    key    = var.test_infra_state_key
    region = var.aws_region
  }
}

# AI 개발 서버의 Security Group과 IAM Role은 AI 인프라 상태에서 참조합니다.
# feat/42-ai-dev-ec2가 기준 브랜치에 병합된 뒤 이 상태를 사용합니다.
data "terraform_remote_state" "ai_dev" {
  backend = "s3"

  config = {
    bucket = var.ai_dev_state_bucket
    key    = var.ai_dev_state_key
    region = var.aws_region
  }
}
