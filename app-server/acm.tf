# ALB HTTPS 리스너용 인증서
resource "aws_acm_certificate" "alb" {
  domain_name       = trimsuffix(var.app_dns_record_name, ".")
  validation_method = "DNS"

  lifecycle {
    create_before_destroy = true
  }

  tags = {
    Name        = "stockspoon-v1-alb"
    Project     = "stockspoon"
    Environment = "v1"
    ManagedBy   = "Terraform"
  }
}

resource "aws_route53_record" "acm_validation" {
  for_each = {
    for option in aws_acm_certificate.alb.domain_validation_options :
    option.domain_name => option
  }

  zone_id         = data.aws_route53_zone.app_alert_email.zone_id
  name            = each.value.resource_record_name
  type            = each.value.resource_record_type
  records         = [each.value.resource_record_value]
  ttl             = 60
  allow_overwrite = true
}

# 인증서가 ISSUED 상태가 될 때까지 apply가 기다린다.
resource "aws_acm_certificate_validation" "alb" {
  certificate_arn         = aws_acm_certificate.alb.arn
  validation_record_fqdns = [for record in aws_route53_record.acm_validation : record.fqdn]
}

output "alb_certificate_arn" {
  description = "ARN of the validated ACM certificate for the application ALB"
  value       = aws_acm_certificate_validation.alb.certificate_arn
}
