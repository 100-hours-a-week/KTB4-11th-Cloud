provider "aws" {
  region = var.aws_region

  # 이 root의 모든 리소스에 공통 태그를 붙인다.
  default_tags {
    tags = {
      Project     = "stockspoon"
      Environment = "prod"
      ManagedBy   = "Terraform"
      Stack       = "ecs"
    }
  }
}
