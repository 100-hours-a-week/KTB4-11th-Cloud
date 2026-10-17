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
  app_dns_points_to_alb        = var.app_dns_target == "alb"
  app_dns_points_to_cloudfront = var.app_dns_target == "cloudfront"
  app_dns_uses_alias           = var.app_dns_target != "ec2"
}

resource "aws_route53_record" "app" {
  count   = var.enable_app_dns ? 1 : 0
  zone_id = data.aws_route53_zone.app[0].zone_id
  name    = var.app_dns_record_name
  type    = "A"

  # TODO: ALB DNS Cutover 및 롤백 시 캐시 영향 시간을 줄이기 위해 임시로 낮게 설정
  ttl     = local.app_dns_uses_alias ? null : 60
  records = local.app_dns_uses_alias ? null : [aws_eip.app.public_ip]

  dynamic "alias" {
    for_each = local.app_dns_points_to_alb ? [1] : []

    content {
      name                   = aws_lb.app.dns_name
      zone_id                = aws_lb.app.zone_id
      evaluate_target_health = true
    }
  }

  dynamic "alias" {
    for_each = local.app_dns_points_to_cloudfront && var.frontend_edge_enabled ? [1] : []
    content {
      name                   = aws_cloudfront_distribution.frontend[0].domain_name
      zone_id                = aws_cloudfront_distribution.frontend[0].hosted_zone_id
      evaluate_target_health = false
    }
  }

  lifecycle {
    precondition {
      condition     = !local.app_dns_points_to_cloudfront || (var.frontend_edge_enabled && var.frontend_assets_ready && var.frontend_v2_origin_ready)
      error_message = "CloudFront cutover requires the edge, uploaded assets, and a verified V2 frontend origin."
    }
  }
}

resource "aws_route53_record" "frontend_ipv6" {
  count   = var.enable_app_dns && local.app_dns_points_to_cloudfront && var.frontend_edge_enabled ? 1 : 0
  zone_id = data.aws_route53_zone.app[0].zone_id
  name    = var.app_dns_record_name
  type    = "AAAA"
  alias {
    name                   = aws_cloudfront_distribution.frontend[0].domain_name
    zone_id                = aws_cloudfront_distribution.frontend[0].hosted_zone_id
    evaluate_target_health = false
  }
}

output "app_dns_target" {
  description = "Current entry point of the application DNS record (ec2, alb, or cloudfront)"
  value       = var.app_dns_target
}

output "app_dns_record_fqdn" {
  description = "Application DNS name managed by Terraform, or null when DNS is disabled"
  value       = var.enable_app_dns ? aws_route53_record.app[0].fqdn : null
}
