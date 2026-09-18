# 애플리케이션 인프라가 배치될 기본 네트워크
resource "aws_vpc" "main" {
  cidr_block           = var.vpc_cidr
  enable_dns_support   = true
  enable_dns_hostnames = true

  tags = {
    Name = "stockspoon-vpc"
  }
}

# EC2가 배치될 Public Subnet
resource "aws_subnet" "public" {
  vpc_id                  = aws_vpc.main.id
  cidr_block              = var.public_subnet_cidr
  availability_zone       = "ap-northeast-2a"
  map_public_ip_on_launch = true

  tags = {
    Name = "stockspoon-public-subnet"
  }
}

# VPC와 인터넷 간 통신을 위한 Internet Gateway
resource "aws_internet_gateway" "main" {
  vpc_id = aws_vpc.main.id

  tags = {
    Name = "stockspoon-igw"
  }
}

# Public Subnet의 트래픽 경로를 관리하는 Route Table
resource "aws_route_table" "public" {
  vpc_id = aws_vpc.main.id

  tags = {
    Name = "stockspoon-public-rt"
  }
}

# 인터넷으로 향하는 모든 IPv4 트래픽을 Internet Gateway로 전달
resource "aws_route" "internet" {
  route_table_id         = aws_route_table.public.id
  destination_cidr_block = "0.0.0.0/0"
  gateway_id             = aws_internet_gateway.main.id
}

# Public Subnet에 Public Route Table 연결
resource "aws_route_table_association" "public" {
  subnet_id      = aws_subnet.public.id
  route_table_id = aws_route_table.public.id
}
