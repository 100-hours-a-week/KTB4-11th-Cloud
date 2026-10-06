resource "aws_security_group" "ai" {
  name        = "stockspoon-v1-ai-sg"
  description = "Security group for StockSpoon V1 AI EC2"
  vpc_id      = data.terraform_remote_state.shared.outputs.vpc_id

  tags = {
    Name        = "stockspoon-v1-ai-sg"
    Project     = "stockspoon"
    Environment = "v1"
    ManagedBy   = "Terraform"
  }
}

resource "aws_vpc_security_group_ingress_rule" "ai_ssh" {
  for_each = toset(var.ssh_allowed_cidrs)

  security_group_id = aws_security_group.ai.id
  cidr_ipv4         = each.value
  from_port         = 22
  to_port           = 22
  ip_protocol       = "tcp"
  description       = "Allow key-only SSH access to the AI host"
}

# App 서버만 AI API 포트에 접근할 수 있습니다.
resource "aws_vpc_security_group_ingress_rule" "ai_api_from_app" {
  security_group_id            = aws_security_group.ai.id
  referenced_security_group_id = data.terraform_remote_state.app.outputs.app_security_group_id
  from_port                    = 8000
  to_port                      = 8000
  ip_protocol                  = "tcp"
  description                  = "Allow the application host to call the AI API"
}

resource "aws_vpc_security_group_egress_rule" "ai_all" {
  security_group_id = aws_security_group.ai.id
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "-1"
  description       = "Allow outbound traffic for package and image downloads"
}
