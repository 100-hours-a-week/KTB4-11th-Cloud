# 참조 방향은 ecs → shared-infra / app-server 단방향으로만 유지한다.
# shared-infra, app-server는 ecs를 참조하지 않는다.

# VPC, Private Subnet
data "terraform_remote_state" "shared" {
  backend = "s3"

  config = {
    bucket = "stockspoon-terraform-state-v1"
    key    = "shared-infra/terraform.tfstate"
    region = "ap-northeast-2"
  }
}

# ALB 리스너, Blue Target Group, ALB·V1 앱 Security Group
data "terraform_remote_state" "app" {
  backend = "s3"

  config = {
    bucket = "stockspoon-terraform-state-v1"
    key    = "app-server/terraform.tfstate"
    region = "ap-northeast-2"
  }
}
