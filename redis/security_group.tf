resource "aws_security_group" "valkey" {
  name        = "${local.name_prefix}-sg"
  description = "Security group for the StockSpoon V2 development Valkey serverless cache"
  vpc_id      = data.aws_vpc.target.id

  tags = {
    Name = "${local.name_prefix}-sg"
  }
}

# 현재 존재하는 AI 개발 서버만 Valkey에 연결할 수 있습니다.
# Backend 개발 서버 Security Group이 생성되면 별도 규칙을 추가합니다.
resource "aws_vpc_security_group_ingress_rule" "valkey_from_ai" {
  security_group_id            = aws_security_group.valkey.id
  referenced_security_group_id = data.terraform_remote_state.ai_dev.outputs.ai_security_group_id
  from_port                    = var.valkey_port
  to_port                      = var.valkey_port
  ip_protocol                  = "tcp"
  description                  = "Allow TLS Valkey traffic from the V2 development AI server"
}

# 응답 트래픽과 VPC 내부 통신만 허용하며 인터넷 목적지 규칙은 만들지 않습니다.
resource "aws_vpc_security_group_egress_rule" "valkey_to_vpc" {
  security_group_id = aws_security_group.valkey.id
  cidr_ipv4         = data.aws_vpc.target.cidr_block
  ip_protocol       = "-1"
  description       = "Allow outbound traffic only inside the target VPC"
}
