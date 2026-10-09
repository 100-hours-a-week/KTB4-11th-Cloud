resource "aws_vpc" "loadtest" {
  cidr_block           = var.vpc_cidr
  enable_dns_support   = true
  enable_dns_hostnames = true

  tags = {
    Name        = "${var.name_prefix}-vpc"
    Project     = "stockspoon"
    Environment = "loadtest"
    ManagedBy   = "Terraform"
  }
}

resource "aws_subnet" "public" {
  vpc_id                  = aws_vpc.loadtest.id
  cidr_block              = var.public_subnet_cidr
  availability_zone       = var.availability_zone
  map_public_ip_on_launch = true

  tags = {
    Name        = "${var.name_prefix}-public-subnet"
    Project     = "stockspoon"
    Environment = "loadtest"
    ManagedBy   = "Terraform"
  }
}

resource "aws_internet_gateway" "loadtest" {
  vpc_id = aws_vpc.loadtest.id

  tags = {
    Name        = "${var.name_prefix}-igw"
    Project     = "stockspoon"
    Environment = "loadtest"
    ManagedBy   = "Terraform"
  }
}

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.loadtest.id

  tags = {
    Name        = "${var.name_prefix}-public-rt"
    Project     = "stockspoon"
    Environment = "loadtest"
    ManagedBy   = "Terraform"
  }
}

resource "aws_route" "internet" {
  route_table_id         = aws_route_table.public.id
  destination_cidr_block = "0.0.0.0/0"
  gateway_id             = aws_internet_gateway.loadtest.id
}

resource "aws_route_table_association" "public" {
  subnet_id      = aws_subnet.public.id
  route_table_id = aws_route_table.public.id
}

# 개발 서비스가 공용으로 사용하는 Private Subnet입니다.
resource "aws_subnet" "private" {
  for_each = var.private_subnets

  vpc_id                  = aws_vpc.loadtest.id
  cidr_block              = each.value.cidr_block
  availability_zone       = each.value.availability_zone
  map_public_ip_on_launch = false

  tags = {
    Name        = "${var.name_prefix}-private-${each.key}"
    Project     = "stockspoon"
    Environment = "dev"
    ManagedBy   = "Terraform"
  }
}

# Internet Gateway와 NAT Gateway 경로를 두지 않고 VPC local 경로만 사용합니다.
resource "aws_route_table" "private" {
  vpc_id = aws_vpc.loadtest.id

  tags = {
    Name        = "${var.name_prefix}-private-rt"
    Project     = "stockspoon"
    Environment = "dev"
    ManagedBy   = "Terraform"
  }
}

resource "aws_route_table_association" "private" {
  for_each = aws_subnet.private

  subnet_id      = each.value.id
  route_table_id = aws_route_table.private.id
}
