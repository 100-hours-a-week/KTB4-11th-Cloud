resource "aws_subnet" "private" {
  for_each = var.private_subnets

  vpc_id                  = aws_vpc.main.id
  cidr_block              = each.value.cidr_block
  availability_zone       = each.value.availability_zone
  map_public_ip_on_launch = false

  tags = {
    Name = "stockspoon-private-subnet-${each.key}"
  }
}

# NAT Gateway에 고정으로 붙일 EIP
resource "aws_eip" "nat" {
  domain = "vpc"

  tags = {
    Name = "stockspoon-nat-eip"
  }
}

# 비용을 고려해 NAT Gateway는 2a Public Subnet에 1개만 배치
# 2a AZ 장애 시 2c의 Private Subnet도 외부 통신이 끊기는 단일 장애 지점이므로, 운영 요구가 커지면 AZ별 NAT Gateway로 전환
resource "aws_nat_gateway" "main" {
  allocation_id = aws_eip.nat.id
  subnet_id     = aws_subnet.public.id

  tags = {
    Name = "stockspoon-nat"
  }

  depends_on = [aws_internet_gateway.main]
}

# Private Subnet이 공통으로 사용하는 Route Table
resource "aws_route_table" "private" {
  vpc_id = aws_vpc.main.id

  tags = {
    Name = "stockspoon-private-rt"
  }
}

# 인터넷으로 향하는 IPv4 트래픽을 NAT Gateway로 전달
resource "aws_route" "private_nat" {
  route_table_id         = aws_route_table.private.id
  destination_cidr_block = "0.0.0.0/0"
  nat_gateway_id         = aws_nat_gateway.main.id
}

resource "aws_route_table_association" "private" {
  for_each = aws_subnet.private

  subnet_id      = each.value.id
  route_table_id = aws_route_table.private.id
}

# S3 트래픽은 NAT를 거치지 않고 Gateway Endpoint로 보내도록 설정
# Private ECR 이미지 레이어가 S3에서 내려오므로 NAT 데이터 처리 비용 절약 (Gateway Endpoint는 무료)
resource "aws_vpc_endpoint" "s3" {
  vpc_id            = aws_vpc.main.id
  service_name      = "com.amazonaws.${var.aws_region}.s3"
  vpc_endpoint_type = "Gateway"
  route_table_ids   = [aws_route_table.private.id]

  tags = {
    Name = "stockspoon-s3-gateway-endpoint"
  }
}
