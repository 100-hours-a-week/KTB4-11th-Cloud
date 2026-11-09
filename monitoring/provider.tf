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

# CloudFront viewer certificates must be requested in us-east-1.
provider "aws" {
  alias  = "us_east_1"
  region = "us-east-1"
  default_tags {
    tags = {
      Project     = "stockspoon"
      Environment = "prod"
      ManagedBy   = "Terraform"
      Stack       = "monitoring"
    }
  }
}
