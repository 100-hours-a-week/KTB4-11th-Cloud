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

# Point the public application hostname at the app server's stable Elastic IP.
resource "aws_route53_record" "app" {
  count   = var.enable_app_dns ? 1 : 0
  zone_id = data.aws_route53_zone.app[0].zone_id
  name    = var.app_dns_record_name
  type    = "A"
  ttl     = 60 # TODO: ALB DNS Cutover 및 롤백 시 캐시 영향 시간을 줄이기 위해 임시로 낮게 설정
  records = [aws_eip.app.public_ip]
}

output "app_dns_record_fqdn" {
  description = "Application DNS name managed by Terraform, or null when DNS is disabled"
  value       = var.enable_app_dns ? aws_route53_record.app[0].fqdn : null
}
