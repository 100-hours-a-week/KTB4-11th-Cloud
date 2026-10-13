# dev: test-infra VPC와 개발 Backend·AI 서버를 참조합니다.
# prod: ECS와 같은 shared-infra VPC를 참조하며, 접근 허용(SG ingress·Policy 연결)은 ecs root가 관리합니다.

data "terraform_remote_state" "test" {
  count   = local.is_dev ? 1 : 0
  backend = "s3"

  config = {
    bucket = var.test_infra_state_bucket
    key    = var.test_infra_state_key
    region = var.aws_region
  }
}

# 개발 AI EC2의 Security Group과 IAM Role
data "terraform_remote_state" "ai_dev" {
  count   = local.is_dev ? 1 : 0
  backend = "s3"

  config = {
    bucket = var.ai_dev_state_bucket
    key    = var.ai_dev_state_key
    region = var.aws_region
  }
}

# 운영 VPC와 Private Subnet(2a, 2c)
data "terraform_remote_state" "shared" {
  count   = local.is_dev ? 0 : 1
  backend = "s3"

  config = {
    bucket = var.shared_infra_state_bucket
    key    = var.shared_infra_state_key
    region = var.aws_region
  }
}
