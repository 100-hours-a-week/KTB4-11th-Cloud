data "aws_security_group" "test_app" {
  name   = var.test_app_security_group_name
  vpc_id = data.terraform_remote_state.test.outputs.vpc_id
}

resource "aws_security_group" "ai" {
  name        = "${local.name_prefix}-sg"
  description = "Security group for the StockSpoon V2 development AI EC2"
  vpc_id      = data.terraform_remote_state.test.outputs.vpc_id

  tags = {
    Name = "${local.name_prefix}-sg"
  }
}

resource "aws_vpc_security_group_ingress_rule" "ai_ssh" {
  for_each = toset(var.ssh_allowed_cidrs)

  security_group_id = aws_security_group.ai.id
  cidr_ipv4         = each.value
  from_port         = 22
  to_port           = 22
  ip_protocol       = "tcp"
  description       = "Allow optional key-only SSH access to the development AI host"
}

resource "aws_vpc_security_group_ingress_rule" "ai_api_from_test_app" {
  security_group_id            = aws_security_group.ai.id
  referenced_security_group_id = data.aws_security_group.test_app.id
  from_port                    = var.ai_api_port
  to_port                      = var.ai_api_port
  ip_protocol                  = "tcp"
  description                  = "Allow the test-infra application host to call the AI API"
}

resource "aws_vpc_security_group_egress_rule" "ai_all" {
  security_group_id = aws_security_group.ai.id
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "-1"
  description       = "Allow outbound traffic for SQS, SSM, Tailscale, and package downloads"
}
