# Lambda and ProxySQL share the V2 application VPC. This root reads only the
# shared network state; it does not depend on the ECS root, avoiding a cycle.
data "terraform_remote_state" "shared" {
  backend = "s3"

  config = {
    bucket = "stockspoon-terraform-state-v1"
    key    = "shared-infra/terraform.tfstate"
    region = "ap-northeast-2"
  }
}
