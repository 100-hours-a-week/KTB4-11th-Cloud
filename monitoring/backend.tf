# ECS uses a different state key in the same existing state bucket.
terraform {
  backend "s3" {
    bucket       = "stockspoon-terraform-state-v2"
    key          = "monitoring/terraform.tfstate"
    region       = "ap-northeast-2"
    use_lockfile = true
    encrypt      = true
  }
}
