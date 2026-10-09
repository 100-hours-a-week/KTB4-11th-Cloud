# Reuse the existing test-infra VPC and public subnet.
data "terraform_remote_state" "test" {
  backend = "s3"

  config = {
    bucket = "stockspoon-terraform-state-v1"
    key    = "test-infra/terraform.tfstate"
    region = "ap-northeast-2"
  }
}

# Consume the SQS URLs and the least-privilege AI policy created by PR #41.
data "terraform_remote_state" "messaging" {
  backend = "s3"

  config = {
    bucket = "stockspoon-terraform-state-sqs"
    key    = "messaging/dev/terraform.tfstate"
    region = "ap-northeast-2"
  }
}
