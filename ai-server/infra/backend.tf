terraform {
  backend "s3" {
    bucket       = "stockspoon-terraform-state-v1"
    key          = "ai-server/infra/terraform.tfstate"
    region       = "ap-northeast-2"
    use_lockfile = true
    encrypt      = true
  }
}
