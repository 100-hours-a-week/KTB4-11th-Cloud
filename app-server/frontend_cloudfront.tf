# Keep the ALB's DNS name as the origin to avoid a loop after apex DNS cutover.
# AllViewer forwards the application's Host, matching the existing ALB certificate.
resource "aws_acm_certificate" "frontend_edge" {
  count             = var.frontend_edge_enabled ? 1 : 0
  provider          = aws.us_east_1
  domain_name       = trimsuffix(var.app_dns_record_name, ".")
  validation_method = "DNS"
  tags              = local.frontend_tags
  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_acm_certificate_validation" "frontend_edge" {
  count           = var.frontend_edge_enabled ? 1 : 0
  provider        = aws.us_east_1
  certificate_arn = aws_acm_certificate.frontend_edge[0].arn
  # ACM uses the same DNS token for the same account/domain across regions.
  # The existing ALB certificate owns these records; do not manage them twice.
  validation_record_fqdns = [for record in aws_route53_record.acm_validation : record.fqdn]
}

resource "aws_cloudfront_origin_access_control" "frontend" {
  count                             = var.frontend_edge_enabled ? 1 : 0
  name                              = "stockspoon-v2-prod-frontend"
  description                       = "Private frontend assets served only through CloudFront"
  origin_access_control_origin_type = "s3"
  signing_behavior                  = "always"
  signing_protocol                  = "sigv4"
}

data "aws_cloudfront_cache_policy" "frontend_disabled" {
  count = var.frontend_edge_enabled ? 1 : 0
  name  = "Managed-CachingDisabled"
}

data "aws_cloudfront_cache_policy" "frontend_static" {
  count = var.frontend_edge_enabled ? 1 : 0
  name  = "Managed-CachingOptimized"
}

data "aws_cloudfront_origin_request_policy" "frontend_dynamic" {
  count = var.frontend_edge_enabled ? 1 : 0
  name  = "Managed-AllViewer"
}

resource "aws_cloudfront_distribution" "frontend" {
  count               = var.frontend_edge_enabled ? 1 : 0
  enabled             = true
  is_ipv6_enabled     = true
  comment             = "StockSpoon V2 frontend: Next.js on ALB, immutable assets on private S3"
  aliases             = [trimsuffix(var.app_dns_record_name, ".")]
  price_class         = var.frontend_price_class
  http_version        = "http2and3"
  wait_for_deployment = true
  tags                = local.frontend_tags

  origin {
    origin_id                = "frontend-assets"
    domain_name              = aws_s3_bucket.frontend_assets[0].bucket_regional_domain_name
    origin_access_control_id = aws_cloudfront_origin_access_control.frontend[0].id
  }

  # API origin deliberately has no frontend routing header, preserving BE canary/rollback.
  dynamic "origin" {
    for_each = toset(["application", "frontend-pages"])
    content {
      origin_id   = origin.value
      domain_name = aws_lb.app.dns_name
      custom_origin_config {
        http_port                = 80
        https_port               = 443
        origin_protocol_policy   = "https-only"
        origin_ssl_protocols     = ["TLSv1.2"]
        origin_read_timeout      = 60
        origin_keepalive_timeout = 5
      }
      custom_header {
        name  = "X-Stockspoon-Frontend"
        value = origin.value == "frontend-pages" && var.frontend_v2_origin_ready ? "v2" : "legacy"
      }
    }
  }

  default_cache_behavior {
    target_origin_id         = "frontend-pages"
    viewer_protocol_policy   = "redirect-to-https"
    allowed_methods          = ["DELETE", "GET", "HEAD", "OPTIONS", "PATCH", "POST", "PUT"]
    cached_methods           = ["GET", "HEAD"]
    cache_policy_id          = data.aws_cloudfront_cache_policy.frontend_disabled[0].id
    origin_request_policy_id = data.aws_cloudfront_origin_request_policy.frontend_dynamic[0].id
    compress                 = true
  }

  dynamic "ordered_cache_behavior" {
    for_each = var.frontend_assets_ready ? ["/_next/static/*"] : []
    content {
      path_pattern           = ordered_cache_behavior.value
      target_origin_id       = "frontend-assets"
      viewer_protocol_policy = "redirect-to-https"
      allowed_methods        = ["GET", "HEAD", "OPTIONS"]
      cached_methods         = ["GET", "HEAD"]
      cache_policy_id        = data.aws_cloudfront_cache_policy.frontend_static[0].id
      compress               = true
    }
  }

  dynamic "ordered_cache_behavior" {
    for_each = ["/api", "/api/*", "/market", "/market/*", "/.well-known/acme-challenge/*"]
    content {
      path_pattern             = ordered_cache_behavior.value
      target_origin_id         = "application"
      viewer_protocol_policy   = "redirect-to-https"
      allowed_methods          = ["DELETE", "GET", "HEAD", "OPTIONS", "PATCH", "POST", "PUT"]
      cached_methods           = ["GET", "HEAD"]
      cache_policy_id          = data.aws_cloudfront_cache_policy.frontend_disabled[0].id
      origin_request_policy_id = data.aws_cloudfront_origin_request_policy.frontend_dynamic[0].id
      compress                 = true
    }
  }

  # Never turn API errors into SPA HTML or cache authentication/server errors.
  dynamic "custom_error_response" {
    for_each = toset([400, 403, 404, 405, 414, 416, 500, 501, 502, 503, 504])
    content {
      error_code            = custom_error_response.value
      error_caching_min_ttl = 0
    }
  }

  restrictions {
    geo_restriction {
      restriction_type = "none"
    }
  }

  viewer_certificate {
    acm_certificate_arn      = aws_acm_certificate_validation.frontend_edge[0].certificate_arn
    ssl_support_method       = "sni-only"
    minimum_protocol_version = "TLSv1.2_2021"
  }
}

output "frontend_edge" {
  description = "FE CI variables; preview dynamic pages using the application Host, not the cloudfront.net Host"
  value = var.frontend_edge_enabled ? {
    assets_bucket    = aws_s3_bucket.frontend_assets[0].id
    distribution_id  = aws_cloudfront_distribution.frontend[0].id
    distribution_arn = aws_cloudfront_distribution.frontend[0].arn
    domain_name      = aws_cloudfront_distribution.frontend[0].domain_name
    deploy_role_arn  = aws_iam_role.frontend_publish[0].arn
    application_host = trimsuffix(var.app_dns_record_name, ".")
  } : null
}
