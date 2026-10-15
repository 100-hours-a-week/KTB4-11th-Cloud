terraform {
  backend "s3" {
    bucket       = "stockspoon-terraform-state-v1"
    key          = "storage/terraform.tfstate"
    region       = "ap-northeast-2"
    use_lockfile = true
    encrypt      = true
  }
}
