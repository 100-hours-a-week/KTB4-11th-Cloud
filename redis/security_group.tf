resource "aws_security_group" "valkey" {
  name        = "${local.name_prefix}-sg"
  description = "Security group for the StockSpoon V2 ${local.environment_label} Valkey serverless cache"
  vpc_id      = data.aws_vpc.target.id

  tags = {
    Name = "${local.name_prefix}-sg"
  }
}

resource "aws_vpc_security_group_ingress_rule" "valkey_from_backend" {
  count = local.backend_security_group_id == null ? 0 : 1

  security_group_id            = aws_security_group.valkey.id
  referenced_security_group_id = local.backend_security_group_id
  from_port                    = var.valkey_port
  to_port                      = var.valkey_port
  ip_protocol                  = "tcp"
  description                  = "Allow the dedicated development application host to connect to Valkey over TLS"
}

resource "aws_vpc_security_group_ingress_rule" "valkey_from_ai" {
  count = local.ai_security_group_id == null ? 0 : 1

  security_group_id            = aws_security_group.valkey.id
  referenced_security_group_id = local.ai_security_group_id
  from_port                    = var.valkey_port
  to_port                      = var.valkey_port
  ip_protocol                  = "tcp"
  description                  = "Allow the development AI host to connect to Valkey over TLS"
}

# prod: ECS Task가 실행되는 Private Subnet(2a, 2c) 전체에서 접근을 허용합니다.
# Public Subnet(V1 EC2, ALB)은 제외되며, 실제 접속 통제는 서비스별 IAM 인증 사용자와 Connect Policy가 담당합니다.
# TODO: ECS 서비스(backend, socket, market-data, match-engine)가 모두 배포되면 ecs root에서
#       Task Security Group별 ingress를 먼저 추가한 뒤 이 CIDR 규칙을 제거해 접근 범위를 좁힙니다.
data "aws_subnet" "private" {
  for_each = local.is_dev ? toset([]) : toset(local.private_subnet_ids)
  id       = each.value
}

resource "aws_vpc_security_group_ingress_rule" "valkey_from_private_subnets" {
  for_each = data.aws_subnet.private

  security_group_id = aws_security_group.valkey.id
  cidr_ipv4         = each.value.cidr_block
  from_port         = var.valkey_port
  to_port           = var.valkey_port
  ip_protocol       = "tcp"
  description       = "Allow ECS tasks in private subnet ${each.value.availability_zone} to connect to Valkey over TLS"
}

# 응답 트래픽과 VPC 내부 통신만 허용하며 인터넷 목적지 규칙은 만들지 않습니다.
resource "aws_vpc_security_group_egress_rule" "valkey_to_vpc" {
  security_group_id = aws_security_group.valkey.id
  cidr_ipv4         = data.aws_vpc.target.cidr_block
  ip_protocol       = "-1"
  description       = "Allow outbound traffic only inside the target VPC"
}
