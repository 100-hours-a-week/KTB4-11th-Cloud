# Valkey는 test-infra가 관리하는 VPC를 재사용합니다.
data "terraform_remote_state" "test" {
  backend = "s3"

  config = {
    bucket = var.test_infra_state_bucket
    key    = var.test_infra_state_key
    region = var.aws_region
  }
}

# 개발 AI EC2의 Security Group과 IAM Role
data "terraform_remote_state" "ai_dev" {
  backend = "s3"

  config = {
    bucket = var.ai_dev_state_bucket
    key    = var.ai_dev_state_key
    region = var.aws_region
  }
}
