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
