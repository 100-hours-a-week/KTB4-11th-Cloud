# Keep this independently operated FIS root out of the ECS service state.
terraform {
  backend "s3" {
    bucket       = "stockspoon-terraform-state-v2"
    key          = "fis/market-http/terraform.tfstate"
    region       = "ap-northeast-2"
    use_lockfile = true
    encrypt      = true
  }
}
