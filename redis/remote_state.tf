# Valkey는 test-infra가 관리하는 VPC를 재사용합니다.
data "terraform_remote_state" "test" {
  backend = "s3"

  config = {
    bucket = var.test_infra_state_bucket
    key    = var.test_infra_state_key
    region = var.aws_region
  }
}
