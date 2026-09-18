provider "aws" {
  region = var.aws_region
}

# Amazon ECR Public resources can only be managed through us-east-1.
# Existing VPC and future EC2 resources continue to use the default Seoul provider above.
provider "aws" {
  alias  = "us_east_1"
  region = "us-east-1"
}
