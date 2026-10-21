# Base monitoring uses shared networking. Optional Grafana HTTPS reads only
# application edge outputs in grafana_https.tf; it never depends on ECS state.
data "terraform_remote_state" "shared" {
  backend = "s3"

  config = {
    bucket = "stockspoon-terraform-state-v1"
    key    = "shared-infra/terraform.tfstate"
    region = "ap-northeast-2"
  }
}
