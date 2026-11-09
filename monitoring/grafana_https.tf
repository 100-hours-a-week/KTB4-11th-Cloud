# Only the Grafana UI is routed through the existing public ALB.
# Application listener/default actions and the DB migration PLG remain unchanged.
data "terraform_remote_state" "app_edge" {
  count   = local.grafana_public_enabled ? 1 : 0
  backend = "s3"
  config = {
    bucket = "stockspoon-terraform-state-v1"
    key    = "app-server/terraform.tfstate"
    region = "ap-northeast-2"
  }
}

data "aws_route53_zone" "grafana" {
  count        = local.grafana_public_enabled ? 1 : 0
  name         = "${trimsuffix(var.grafana_route53_zone_name, ".")}."
  private_zone = false
}

resource "aws_acm_certificate" "grafana" {
  count             = local.grafana_public_enabled ? 1 : 0
  domain_name       = var.grafana_domain_name
  validation_method = "DNS"
  lifecycle {
    create_before_destroy = true
    precondition {
      condition     = endswith(var.grafana_domain_name, ".${trimsuffix(var.grafana_route53_zone_name, ".")}")
      error_message = "Grafana must use a subdomain of the selected public hosted zone."
    }
  }
}

resource "aws_route53_record" "grafana_certificate" {
  for_each = local.grafana_public_enabled ? {
    (var.grafana_domain_name) = one(aws_acm_certificate.grafana[0].domain_validation_options)
  } : {}
  zone_id = data.aws_route53_zone.grafana[0].zone_id
  name    = each.value.resource_record_name
  type    = each.value.resource_record_type
  records = [each.value.resource_record_value]
  ttl     = 60
}

resource "aws_acm_certificate_validation" "grafana" {
  count                   = local.grafana_public_enabled ? 1 : 0
  certificate_arn         = aws_acm_certificate.grafana[0].arn
  validation_record_fqdns = [for record in aws_route53_record.grafana_certificate : record.fqdn]
}

# CloudFront viewer certificates must be in us-east-1. ACM's DNS validation
# record for this hostname is reusable across regions in the same account.
resource "aws_acm_certificate" "grafana_cloudfront" {
  count             = local.grafana_public_enabled ? 1 : 0
  provider          = aws.us_east_1
  domain_name       = var.grafana_domain_name
  validation_method = "DNS"

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_acm_certificate_validation" "grafana_cloudfront" {
  count                   = local.grafana_public_enabled ? 1 : 0
  provider                = aws.us_east_1
  certificate_arn         = aws_acm_certificate.grafana_cloudfront[0].arn
  validation_record_fqdns = [for record in aws_route53_record.grafana_certificate : record.fqdn]
}

data "aws_cloudfront_cache_policy" "grafana_disabled" {
  count = local.grafana_public_enabled ? 1 : 0
  name  = "Managed-CachingDisabled"
}

data "aws_cloudfront_origin_request_policy" "grafana_all_viewer" {
  count = local.grafana_public_enabled ? 1 : 0
  name  = "Managed-AllViewer"
}

resource "aws_lb_listener_certificate" "grafana" {
  count           = local.grafana_public_enabled ? 1 : 0
  listener_arn    = data.terraform_remote_state.app_edge[0].outputs.https_listener_arn
  certificate_arn = aws_acm_certificate_validation.grafana[0].certificate_arn
}

# Keep the public Grafana hostname available after the ALB ingress is limited
# to CloudFront. The ALB listener still selects this target by the viewer Host.
# The application API rate-limit WebACL is intentionally not attached here;
# Grafana itself uses /api/* routes which would share that rate bucket.
resource "aws_cloudfront_distribution" "grafana" {
  count               = local.grafana_public_enabled ? 1 : 0
  enabled             = true
  is_ipv6_enabled     = true
  comment             = "StockSpoon production Grafana through CloudFront"
  aliases             = [var.grafana_domain_name]
  price_class         = "PriceClass_All"
  http_version        = "http2and3"
  wait_for_deployment = true

  origin {
    domain_name = data.terraform_remote_state.app_edge[0].outputs.alb_dns_name
    origin_id   = "grafana-alb"

    custom_origin_config {
      http_port                = 80
      https_port               = 443
      origin_protocol_policy   = "https-only"
      origin_ssl_protocols     = ["TLSv1.2"]
      origin_read_timeout      = 60
      origin_keepalive_timeout = 5
    }
  }

  default_cache_behavior {
    target_origin_id         = "grafana-alb"
    viewer_protocol_policy   = "redirect-to-https"
    allowed_methods          = ["DELETE", "GET", "HEAD", "OPTIONS", "PATCH", "POST", "PUT"]
    cached_methods           = ["GET", "HEAD"]
    cache_policy_id          = data.aws_cloudfront_cache_policy.grafana_disabled[0].id
    origin_request_policy_id = data.aws_cloudfront_origin_request_policy.grafana_all_viewer[0].id
    compress                 = true
  }

  restrictions {
    geo_restriction {
      restriction_type = "none"
    }
  }

  viewer_certificate {
    acm_certificate_arn      = aws_acm_certificate_validation.grafana_cloudfront[0].certificate_arn
    ssl_support_method       = "sni-only"
    minimum_protocol_version = "TLSv1.2_2021"
  }

  depends_on = [
    aws_lb_listener_certificate.grafana,
    aws_lb_listener_rule.grafana,
  ]
}

resource "aws_lb_target_group" "grafana" {
  count       = local.grafana_public_enabled ? 1 : 0
  name_prefix = "graf-"
  port        = 3000
  protocol    = "HTTP"
  target_type = "instance"
  vpc_id      = data.terraform_remote_state.shared.outputs.vpc_id

  deregistration_delay = 30
  health_check {
    path                = "/api/health"
    matcher             = "200"
    healthy_threshold   = 2
    unhealthy_threshold = 2
    interval            = 30
    timeout             = 5
  }
  tags = { Name = "${local.telemetry_name}-grafana" }
}

resource "aws_lb_target_group_attachment" "grafana" {
  count            = local.grafana_public_enabled ? 1 : 0
  target_group_arn = aws_lb_target_group.grafana[0].arn
  target_id        = aws_instance.telemetry[0].id
  port             = 3000
}

resource "aws_vpc_security_group_ingress_rule" "grafana_from_alb" {
  count                        = local.grafana_public_enabled ? 1 : 0
  security_group_id            = aws_security_group.telemetry[0].id
  referenced_security_group_id = data.terraform_remote_state.app_edge[0].outputs.alb_security_group_id
  from_port                    = 3000
  to_port                      = 3000
  ip_protocol                  = "tcp"
  description                  = "Grafana UI and health checks from the application ALB only"
}

resource "aws_vpc_security_group_egress_rule" "alb_to_grafana" {
  count                        = local.grafana_public_enabled ? 1 : 0
  security_group_id            = data.terraform_remote_state.app_edge[0].outputs.alb_security_group_id
  referenced_security_group_id = aws_security_group.telemetry[0].id
  from_port                    = 3000
  to_port                      = 3000
  ip_protocol                  = "tcp"
  description                  = "Application ALB to private Grafana only"
}

resource "aws_lb_listener_rule" "grafana" {
  count        = local.grafana_public_enabled ? 1 : 0
  listener_arn = data.terraform_remote_state.app_edge[0].outputs.https_listener_arn
  priority     = var.grafana_listener_rule_priority
  action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.grafana[0].arn
  }
  condition {
    host_header {
      values = [var.grafana_domain_name]
    }
  }
  depends_on = [
    aws_lb_listener_certificate.grafana,
    aws_vpc_security_group_ingress_rule.grafana_from_alb,
    aws_vpc_security_group_egress_rule.alb_to_grafana,
  ]
}

resource "aws_route53_record" "grafana" {
  count   = local.grafana_public_enabled ? 1 : 0
  zone_id = data.aws_route53_zone.grafana[0].zone_id
  name    = var.grafana_domain_name
  type    = "A"
  alias {
    name                   = aws_cloudfront_distribution.grafana[0].domain_name
    zone_id                = aws_cloudfront_distribution.grafana[0].hosted_zone_id
    evaluate_target_health = false
  }
  depends_on = [aws_lb_listener_rule.grafana, aws_cloudfront_distribution.grafana]
}

resource "aws_route53_record" "grafana_ipv6" {
  count   = local.grafana_public_enabled ? 1 : 0
  zone_id = data.aws_route53_zone.grafana[0].zone_id
  name    = var.grafana_domain_name
  type    = "AAAA"
  alias {
    name                   = aws_cloudfront_distribution.grafana[0].domain_name
    zone_id                = aws_cloudfront_distribution.grafana[0].hosted_zone_id
    evaluate_target_health = false
  }
  depends_on = [aws_lb_listener_rule.grafana, aws_cloudfront_distribution.grafana]
}
