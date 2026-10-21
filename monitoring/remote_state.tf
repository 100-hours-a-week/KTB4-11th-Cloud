# Monitoring depends only on shared networking, never on ECS or DB migration.
data "terraform_remote_state" "shared" {
  backend = "s3"

  config = {
    bucket = "stockspoon-terraform-state-v1"
    key    = "shared-infra/terraform.tfstate"
    region = "ap-northeast-2"
  }
}
