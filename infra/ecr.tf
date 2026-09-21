# Public repository that stores backend container images.
# Amazon ECR Public resources must use the us-east-1 provider alias.
resource "aws_ecrpublic_repository" "backend" {
  provider = aws.us_east_1

  repository_name = var.public_ecr_repository_name

  catalog_data {
    description       = "StockSpoon V1 backend application image"
    operating_systems = ["Linux"]
  }

  tags = {
    Name        = var.public_ecr_repository_name
    Project     = "stockspoon"
    Environment = "v1"
    ManagedBy   = "Terraform"
  }
}

# Public repository that stores frontend container images.
resource "aws_ecrpublic_repository" "frontend" {
  provider = aws.us_east_1

  repository_name = var.public_ecr_frontend_repository_name

  catalog_data {
    description       = "StockSpoon V1 frontend application image"
    operating_systems = ["Linux"]
  }

  tags = {
    Name        = var.public_ecr_frontend_repository_name
    Project     = "stockspoon"
    Environment = "v1"
    ManagedBy   = "Terraform"
  }
}

# Public repository that stores AI container images.
resource "aws_ecrpublic_repository" "ai" {
  provider = aws.us_east_1

  repository_name = var.public_ecr_ai_repository_name

  catalog_data {
    description       = "StockSpoon V1 AI application image"
    operating_systems = ["Linux"]
  }

  tags = {
    Name        = var.public_ecr_ai_repository_name
    Project     = "stockspoon"
    Environment = "v1"
    ManagedBy   = "Terraform"
  }
}
