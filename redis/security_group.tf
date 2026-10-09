resource "aws_security_group" "valkey" {
  name        = "${local.name_prefix}-sg"
  description = "Security group for the StockSpoon V2 development Valkey serverless cache"
  vpc_id      = data.aws_vpc.target.id

  tags = {
    Name = "${local.name_prefix}-sg"
  }
}

# Backend 개발 서버가 아직 없으므로 인바운드 규칙을 만들지 않습니다.
# 서버 생성 후 Backend Security Group을 소스로 하는 TCP 6379 규칙을 추가합니다.

# 응답 트래픽과 VPC 내부 통신만 허용하며 인터넷 목적지 규칙은 만들지 않습니다.
resource "aws_vpc_security_group_egress_rule" "valkey_to_vpc" {
  security_group_id = aws_security_group.valkey.id
  cidr_ipv4         = data.aws_vpc.target.cidr_block
  ip_protocol       = "-1"
  description       = "Allow outbound traffic only inside the target VPC"
}
