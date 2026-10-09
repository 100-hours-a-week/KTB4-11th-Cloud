# Terraform과 AWS Provider 버전 및 AI 대시보드 전용 원격 state를 설정합니다.
terraform {
  required_version = ">= 1.10.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
  }

  backend "s3" {
    bucket       = "stockspoon-terraform-state-v1"
    key          = "ai-server/dashboard/terraform.tfstate"
    region       = "ap-northeast-2"
    use_lockfile = true
    encrypt      = true
  }
}
