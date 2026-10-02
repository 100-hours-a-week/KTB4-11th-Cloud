resource "aws_security_group" "app" {
  name        = "${var.name_prefix}-app-sg"
  description = "Security group for the load-test application host"
  vpc_id      = aws_vpc.loadtest.id

  tags = {
    Name        = "${var.name_prefix}-app-sg"
    Project     = "stockspoon"
    Environment = "loadtest"
    ManagedBy   = "Terraform"
  }
}

resource "aws_vpc_security_group_ingress_rule" "app_http" {
  security_group_id = aws_security_group.app.id
  cidr_ipv4         = "0.0.0.0/0"
  from_port         = 80
  to_port           = 80
  ip_protocol       = "tcp"
  description       = "Allow HTTP traffic to the test application"
}

resource "aws_vpc_security_group_ingress_rule" "app_https" {
  security_group_id = aws_security_group.app.id
  cidr_ipv4         = "0.0.0.0/0"
  from_port         = 443
  to_port           = 443
  ip_protocol       = "tcp"
  description       = "Allow HTTPS traffic to the test application"
}

resource "aws_vpc_security_group_ingress_rule" "app_backend_from_k6" {
  security_group_id            = aws_security_group.app.id
  referenced_security_group_id = aws_security_group.k6.id
  from_port                    = 8080
  to_port                      = 8080
  ip_protocol                  = "tcp"
  description                  = "Allow direct backend load-test traffic from the k6 security group"
}

resource "aws_vpc_security_group_ingress_rule" "app_ssh" {
  for_each = toset(var.ssh_allowed_cidrs)

  security_group_id = aws_security_group.app.id
  cidr_ipv4         = each.value
  from_port         = 22
  to_port           = 22
  ip_protocol       = "tcp"
  description       = "Optional key-based SSH access"
}

resource "aws_vpc_security_group_egress_rule" "app_all" {
  security_group_id = aws_security_group.app.id
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "-1"
  description       = "Allow outbound traffic"
}

resource "aws_security_group" "k6" {
  name        = "${var.name_prefix}-k6-sg"
  description = "Security group for the k6 load generator"
  vpc_id      = aws_vpc.loadtest.id

  tags = {
    Name        = "${var.name_prefix}-k6-sg"
    Project     = "stockspoon"
    Environment = "loadtest"
    ManagedBy   = "Terraform"
  }
}

resource "aws_vpc_security_group_ingress_rule" "k6_ssh" {
  for_each = toset(var.ssh_allowed_cidrs)

  security_group_id = aws_security_group.k6.id
  cidr_ipv4         = each.value
  from_port         = 22
  to_port           = 22
  ip_protocol       = "tcp"
  description       = "Optional key-based SSH access"
}

resource "aws_vpc_security_group_egress_rule" "k6_all" {
  security_group_id = aws_security_group.k6.id
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "-1"
  description       = "Allow k6 outbound traffic"
}
