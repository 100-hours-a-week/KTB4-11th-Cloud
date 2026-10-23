resource "aws_security_group" "sse_k6" {
  name        = "${var.name_prefix}-sse-k6-sg"
  description = "Dedicated security group for the SSE load generator"
  vpc_id      = data.terraform_remote_state.test_infra.outputs.vpc_id

  tags = {
    Name        = "${var.name_prefix}-sse-k6-sg"
    Project     = "stockspoon"
    Environment = "loadtest"
    ManagedBy   = "Terraform"
  }
}

resource "aws_vpc_security_group_ingress_rule" "sse_k6_ssh" {
  for_each = toset(var.ssh_allowed_cidrs)

  security_group_id = aws_security_group.sse_k6.id
  cidr_ipv4         = each.value
  from_port         = 22
  to_port           = 22
  ip_protocol       = "tcp"
  description       = "Key-based SSH access to the dedicated SSE load generator"
}

resource "aws_vpc_security_group_egress_rule" "sse_k6_all" {
  security_group_id = aws_security_group.sse_k6.id
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "-1"
  description       = "Allow outbound load-test and bootstrap traffic"
}
