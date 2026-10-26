# 기존 EC2(Nginx) 앞단의 ALB

locals {
  alb_tags = {
    Project     = "stockspoon"
    Environment = "v1"
    ManagedBy   = "Terraform"
  }
}

# ---------------------------------------------------------------------------
# Security Group
# ---------------------------------------------------------------------------

resource "aws_security_group" "alb" {
  name        = "stockspoon-v1-alb-sg"
  description = "Security group for StockSpoon V1 application load balancer"
  vpc_id      = data.terraform_remote_state.shared.outputs.vpc_id

  tags = merge(local.alb_tags, { Name = "stockspoon-v1-alb-sg" })
}

resource "aws_vpc_security_group_ingress_rule" "alb_http" {
  security_group_id = aws_security_group.alb.id
  cidr_ipv4         = "0.0.0.0/0"
  from_port         = 80
  to_port           = 80
  ip_protocol       = "tcp"
  description       = "Allow HTTP for HTTPS redirect and ACME challenge"
}

resource "aws_vpc_security_group_ingress_rule" "alb_https" {
  security_group_id = aws_security_group.alb.id
  cidr_ipv4         = "0.0.0.0/0"
  from_port         = 443
  to_port           = 443
  ip_protocol       = "tcp"
  description       = "Allow HTTPS traffic"
}

resource "aws_vpc_security_group_egress_rule" "alb_to_app_http" {
  security_group_id            = aws_security_group.alb.id
  referenced_security_group_id = aws_security_group.app.id
  from_port                    = 80
  to_port                      = 80
  ip_protocol                  = "tcp"
  description                  = "Forward ACME challenge to app Nginx"
}

resource "aws_vpc_security_group_egress_rule" "alb_to_app_https" {
  security_group_id            = aws_security_group.alb.id
  referenced_security_group_id = aws_security_group.app.id
  from_port                    = 443
  to_port                      = 443
  ip_protocol                  = "tcp"
  description                  = "Forward application traffic and health checks to app Nginx"
}

# ---------------------------------------------------------------------------
# Target Groups
# ---------------------------------------------------------------------------

# Blue: 기존 EC2 Nginx(HTTPS). ALB는 타깃 인증서를 검증하지 않으므로 Let's Encrypt 인증서를 그대로 사용한다.
resource "aws_lb_target_group" "blue" {
  name        = "stockspoon-v1-blue-https"
  port        = 443
  protocol    = "HTTPS"
  target_type = "instance"
  vpc_id      = data.terraform_remote_state.shared.outputs.vpc_id

  # 이 단계에서는 EC2를 빼는 일이 없으므로 짧게 둔다. ECS 전환 시 Green TG에서 별도 조정.
  deregistration_delay = 60

  health_check {
    enabled             = true
    protocol            = "HTTPS"
    path                = "/actuator/health"
    matcher             = "200"
    interval            = 10
    timeout             = 5
    healthy_threshold   = 2
    unhealthy_threshold = 2
  }

  tags = merge(local.alb_tags, { Name = "stockspoon-v1-blue-https" })
}

# Let's Encrypt HTTP-01 갱신 전용(HTTP:80). Nginx 80 서버는 /를 301로 응답하므로 301을 정상으로 본다.
resource "aws_lb_target_group" "acme" {
  name        = "stockspoon-v1-acme-http"
  port        = 80
  protocol    = "HTTP"
  target_type = "instance"
  vpc_id      = data.terraform_remote_state.shared.outputs.vpc_id

  deregistration_delay = 10

  health_check {
    enabled             = true
    protocol            = "HTTP"
    path                = "/"
    matcher             = "301"
    interval            = 30
    timeout             = 5
    healthy_threshold   = 2
    unhealthy_threshold = 2
  }

  tags = merge(local.alb_tags, { Name = "stockspoon-v1-acme-http" })
}

resource "aws_lb_target_group_attachment" "blue_app" {
  target_group_arn = aws_lb_target_group.blue.arn
  target_id        = aws_instance.app.id
  port             = 443
}

resource "aws_lb_target_group_attachment" "acme_app" {
  target_group_arn = aws_lb_target_group.acme.arn
  target_id        = aws_instance.app.id
  port             = 80
}

# ---------------------------------------------------------------------------
# Load Balancer
# ---------------------------------------------------------------------------

resource "aws_lb" "app" {
  name               = "stockspoon-v1-alb"
  internal           = false
  load_balancer_type = "application"
  security_groups    = [aws_security_group.alb.id]
  subnets            = data.terraform_remote_state.shared.outputs.public_subnet_ids

  # 비정상 헤더 필드를 가진 요청은 타깃으로 전달하지 않는다.
  drop_invalid_header_fields = true
  enable_deletion_protection = true
  # Nginx keepalive_timeout(기본 75s)보다 짧게 유지해야 ALB→Nginx 연결이 먼저 끊기지 않으므로 60s로 둔다.
  idle_timeout = 60

  access_logs {
    bucket  = aws_s3_bucket.alb_logs.id
    prefix  = local.alb_access_log_prefix
    enabled = true
  }

  # 로그 버킷 정책이 먼저 있어야 ALB 생성 시 로그 전송 검증을 통과
  depends_on = [aws_s3_bucket_policy.alb_logs]

  tags = merge(local.alb_tags, { Name = "stockspoon-v1-alb" })
}

# ---------------------------------------------------------------------------
# Listeners
# ---------------------------------------------------------------------------

resource "aws_lb_listener" "https" {
  load_balancer_arn = aws_lb.app.arn
  port              = 443
  protocol          = "HTTPS"
  ssl_policy        = "ELBSecurityPolicy-TLS13-1-2-2021-06"
  certificate_arn   = aws_acm_certificate_validation.alb.certificate_arn

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.blue.arn
  }

  tags = merge(local.alb_tags, { Name = "stockspoon-v1-alb-https" })
}

resource "aws_lb_listener" "http" {
  load_balancer_arn = aws_lb.app.arn
  port              = 80
  protocol          = "HTTP"

  default_action {
    type = "redirect"

    redirect {
      port        = "443"
      protocol    = "HTTPS"
      status_code = "HTTP_301"
    }
  }

  tags = merge(local.alb_tags, { Name = "stockspoon-v1-alb-http" })
}

# ACME challenge만 리다이렉트하지 않고 EC2 Nginx:80으로 전달
resource "aws_lb_listener_rule" "acme_challenge" {
  listener_arn = aws_lb_listener.http.arn
  priority     = 10

  action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.acme.arn
  }

  condition {
    path_pattern {
      values = ["/.well-known/acme-challenge/*"]
    }
  }

  tags = merge(local.alb_tags, { Name = "stockspoon-v1-alb-acme" })
}

# ---------------------------------------------------------------------------
# Outputs
# ---------------------------------------------------------------------------

output "alb_dns_name" {
  description = "DNS name of the application ALB (use with curl --resolve before DNS cutover)"
  value       = aws_lb.app.dns_name
}

output "alb_zone_id" {
  description = "Route 53 hosted zone ID of the application ALB, used for alias records"
  value       = aws_lb.app.zone_id
}

# 아래 output은 ecs root가 리스너 규칙·Target Group·SG 규칙을 연결할 때 참조
# 참조는 ecs → app-server 단방향으로만 하며, app-server는 ecs를 참조하지 않는다.

output "alb_arn_suffix" {
  description = "ARN suffix of the application ALB, used for CloudWatch metrics and alarms"
  value       = aws_lb.app.arn_suffix
}

output "alb_security_group_id" {
  description = "ID of the application ALB security group"
  value       = aws_security_group.alb.id
}

output "https_listener_arn" {
  description = "ARN of the ALB HTTPS listener, used to attach ECS listener rules"
  value       = aws_lb_listener.https.arn
}

output "blue_target_group_arn" {
  description = "ARN of the Blue target group (existing EC2 Nginx), used for weighted canary rules"
  value       = aws_lb_target_group.blue.arn
}
