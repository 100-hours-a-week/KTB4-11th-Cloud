locals {
  app_route53_zone_fqdn = format("%s.", trimsuffix(var.route53_zone_name, "."))
}

# Reuse the public hosted zone created for the domain; Terraform manages only
# the application record, not the hosted zone or domain registration.
data "aws_route53_zone" "app" {
  count        = var.enable_app_dns ? 1 : 0
  name         = local.app_route53_zone_fqdn
  private_zone = false
}

# 앱 도메인이 가리킬 진입점
# - ec2: 기존 EC2 Elastic IP (A 레코드, TTL 60)
# - alb: ALB Alias 레코드 (TTL은 Route 53이 60초로 고정)
# DNS 전환과 롤백은 이 값 한 줄만 바꾼다. 같은 이름·타입이므로 레코드 교체 없이 in-place로 변경된다.
locals {
  app_dns_points_to_alb = var.app_dns_target == "alb"
}

resource "aws_route53_record" "app" {
  count   = var.enable_app_dns ? 1 : 0
  zone_id = data.aws_route53_zone.app[0].zone_id
  name    = var.app_dns_record_name
  type    = "A"

  # TODO: ALB DNS Cutover 및 롤백 시 캐시 영향 시간을 줄이기 위해 임시로 낮게 설정
  ttl     = local.app_dns_points_to_alb ? null : 60
  records = local.app_dns_points_to_alb ? null : [aws_eip.app.public_ip]

  dynamic "alias" {
    for_each = local.app_dns_points_to_alb ? [1] : []

    content {
      name                   = aws_lb.app.dns_name
      zone_id                = aws_lb.app.zone_id
      evaluate_target_health = true
    }
  }
}

output "app_dns_target" {
  description = "Current entry point of the application DNS record (ec2 or alb)"
  value       = var.app_dns_target
}

output "app_dns_record_fqdn" {
  description = "Application DNS name managed by Terraform, or null when DNS is disabled"
  value       = var.enable_app_dns ? aws_route53_record.app[0].fqdn : null
}
