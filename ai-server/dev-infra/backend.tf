terraform {
  backend "s3" {
    bucket       = "stockspoon-terraform-state-ai-dev"
    key          = "ai-server/dev-infra/terraform.tfstate"
    region       = "ap-northeast-2"
    use_lockfile = true
    encrypt      = true
  }
}
