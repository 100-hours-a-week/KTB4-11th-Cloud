# 애플리케이션 EC2의 인바운드/아웃바운드 트래픽을 제어하는 Security Group
resource "aws_security_group" "app" {
  name        = "stockspoon-v1-app-sg"
  description = "Security group for StockSpoon V1 application server"
  vpc_id      = data.terraform_remote_state.shared.outputs.vpc_id

  tags = {
    Name = "stockspoon-v1-app-sg"
  }
}

# 외부에서 HTTP(80) 요청 허용
resource "aws_vpc_security_group_ingress_rule" "http" {
  security_group_id = aws_security_group.app.id

  cidr_ipv4   = "0.0.0.0/0"
  from_port   = 80
  to_port     = 80
  ip_protocol = "tcp"

  description = "Allow HTTP traffic"
}

# 외부에서 HTTPS(443) 요청 허용
resource "aws_vpc_security_group_ingress_rule" "https" {
  security_group_id = aws_security_group.app.id

  cidr_ipv4   = "0.0.0.0/0"
  from_port   = 443
  to_port     = 443
  ip_protocol = "tcp"

  description = "Allow HTTPS traffic"
}

# GitHub-hosted runners do not have one fixed outbound IP address.
# For V1, SSH is reachable from the internet but accepts the registered key only;
# password and root logins are disabled by user-data.sh.
resource "aws_vpc_security_group_ingress_rule" "ssh" {
  for_each = toset(var.ssh_allowed_cidrs)

  security_group_id = aws_security_group.app.id

  cidr_ipv4   = each.value
  from_port   = 22
  to_port     = 22
  ip_protocol = "tcp"

  description = "Allow key-only SSH deployment access"
}

# EC2에서 외부로 나가는 모든 트래픽 허용
resource "aws_vpc_security_group_egress_rule" "all" {
  security_group_id = aws_security_group.app.id

  cidr_ipv4   = "0.0.0.0/0"
  ip_protocol = "-1"

  description = "Allow all outbound traffic"
}

# ALB에서 오는 트래픽 허용.
# 기존 0.0.0.0/0 80/443 규칙은 EIP 직접 접속(롤백 경로)을 위해 유지하며,
# 이 규칙은 향후 직접 접속을 닫을 때도 ALB 경로가 유지되도록 명시해 둔다.
resource "aws_vpc_security_group_ingress_rule" "http_from_alb" {
  security_group_id            = aws_security_group.app.id
  referenced_security_group_id = aws_security_group.alb.id
  from_port                    = 80
  to_port                      = 80
  ip_protocol                  = "tcp"
  description                  = "Allow ACME challenge from ALB"
}

resource "aws_vpc_security_group_ingress_rule" "https_from_alb" {
  security_group_id            = aws_security_group.app.id
  referenced_security_group_id = aws_security_group.alb.id
  from_port                    = 443
  to_port                      = 443
  ip_protocol                  = "tcp"
  description                  = "Allow application traffic and health checks from ALB"
}
