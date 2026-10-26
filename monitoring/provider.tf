provider "aws" {
  region = var.aws_region
  default_tags {
    tags = {
      Project     = "stockspoon"
      Environment = "prod"
      ManagedBy   = "Terraform"
      Stack       = "monitoring"
    }
  }
}
