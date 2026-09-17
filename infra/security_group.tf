# 애플리케이션 EC2의 인바운드/아웃바운드 트래픽을 제어하는 Security Group
resource "aws_security_group" "app" {
  name        = "stockspoon-v1-app-sg"
  description = "Security group for StockSpoon V1 application server"
  vpc_id      = aws_vpc.main.id

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

# EC2에서 외부로 나가는 모든 트래픽 허용
resource "aws_vpc_security_group_egress_rule" "all" {
  security_group_id = aws_security_group.app.id

  cidr_ipv4   = "0.0.0.0/0"
  ip_protocol = "-1"

  description = "Allow all outbound traffic"
}
