# VPC와 subnet은 워크로드와 분리된 shared-infra state가 관리합니다.
data "terraform_remote_state" "shared" {
  backend = "s3"

  config = {
    bucket = "stockspoon-terraform-state-v1"
    key    = "shared-infra/terraform.tfstate"
    region = "ap-northeast-2"
  }
}

# AI API ingress에서 참조하는 App Security Group은 기존 infra가 관리합니다.
data "terraform_remote_state" "app" {
  backend = "s3"

  config = {
    bucket = "stockspoon-terraform-state-v1"
    key    = "terraform.tfstate"
    region = "ap-northeast-2"
  }
}
