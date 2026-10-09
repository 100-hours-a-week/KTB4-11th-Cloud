# 애플리케이션별 state와 분리된 공통 네트워크 전용 state입니다.
terraform {
  backend "s3" {
    bucket       = "stockspoon-terraform-state-v1"
    key          = "shared-infra/terraform.tfstate"
    region       = "ap-northeast-2"
    use_lockfile = true
    encrypt      = true
  }
}
