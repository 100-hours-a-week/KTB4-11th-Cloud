data "aws_caller_identity" "current" {}

data "aws_partition" "current" {}

data "terraform_remote_state" "test_infra" {
  backend = "s3"
  config = {
    bucket = "stockspoon-terraform-state-v1"
    key    = "test-infra/terraform.tfstate"
    region = var.aws_region
  }
}
