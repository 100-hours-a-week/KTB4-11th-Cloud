terraform {
  backend "s3" {
    bucket       = "stockspoon-terraform-state-v1"
    key          = "test-infra/terraform.tfstate"
    region       = "ap-northeast-2"
    use_lockfile = true
    encrypt      = true
  }
}
