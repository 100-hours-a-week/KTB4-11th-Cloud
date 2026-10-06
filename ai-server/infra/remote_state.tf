# 공통 VPC, subnet, App Security Group은 기존 infra가 계속 관리합니다.
data "terraform_remote_state" "core" {
  backend = "s3"

  config = {
    bucket = "stockspoon-terraform-state-v1"
    key    = "terraform.tfstate"
    region = "ap-northeast-2"
  }
}
