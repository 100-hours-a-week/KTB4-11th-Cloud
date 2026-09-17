# 애플리케이션 인프라가 배치될 기본 네트워크
resource "aws_vpc" "main" {
  cidr_block           = var.vpc_cidr
  enable_dns_support   = true
  enable_dns_hostnames = true

  tags = {
    Name = "stockspoon-vpc"
  }
}
