# Separate security group for the AI host. The API is reachable only from the
# existing application EC2 security group; SSH follows the existing key-only
# deployment access CIDRs.
resource "aws_security_group" "ai" {
  name        = "stockspoon-v1-ai-sg"
  description = "Security group for StockSpoon V1 AI EC2"
  vpc_id      = aws_vpc.main.id

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

# The AI news-clusterer API listens on 8000; expose it only to the BE host.
resource "aws_vpc_security_group_ingress_rule" "ai_api_from_app" {
  security_group_id            = aws_security_group.ai.id
  referenced_security_group_id = aws_security_group.app.id
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
