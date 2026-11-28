terraform {
  backend "s3" {
    bucket       = "stockspoon-terraform-state-v2"
    key          = "fis/database/terraform.tfstate"
    region       = "ap-northeast-2"
    use_lockfile = true
    encrypt      = true
  }
}
