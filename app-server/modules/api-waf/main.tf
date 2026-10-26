terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
  }
}

variable "request_limit" {
  description = "Experimental per-IP limit: 6.8 calls * 2 visits * 10 users * 3 margin = 408, rounded to 500."
  type        = number
  default     = 500
  validation {
    condition     = var.request_limit >= 10 && var.request_limit <= 2000000000 && floor(var.request_limit) == var.request_limit
    error_message = "request_limit must be an integer between 10 and 2000000000."
  }
}

variable "evaluation_window_sec" {
  type    = number
  default = 300
  validation {
    condition     = contains([60, 120, 300, 600], var.evaluation_window_sec)
    error_message = "Use a WAF evaluation window of 60, 120, 300 or 600 seconds."
  }
}

variable "mode" {
  description = "Count observes threshold breaches; block enforces them only after validation."
  type        = string
  default     = "count"
  validation {
    condition     = contains(["count", "block"], var.mode)
    error_message = "mode must be count or block."
  }
}

resource "aws_wafv2_web_acl" "api" {
  name        = "stockspoon-api-rate-limit"
  description = "Experimental API flood protection; limits are hypotheses, not measured user traffic."
  scope       = "CLOUDFRONT"

  default_action {
    allow {}
  }

  rule {
    name     = "api-per-source-ip"
    priority = 0
    action {
      dynamic "count" {
        for_each = var.mode == "count" ? [1] : []
        content {}
      }
      dynamic "block" {
        for_each = var.mode == "block" ? [1] : []
        content {
          custom_response {
            response_code = 429
          }
        }
      }
    }
    statement {
      rate_based_statement {
        aggregate_key_type    = "IP"
        limit                 = var.request_limit
        evaluation_window_sec = var.evaluation_window_sec
        scope_down_statement {
          byte_match_statement {
            field_to_match {
              uri_path {}
            }
            positional_constraint = "STARTS_WITH"
            search_string         = "/api/"
            text_transformation {
              priority = 0
              type     = "NONE"
            }
          }
        }
      }
    }
    visibility_config {
      cloudwatch_metrics_enabled = true
      metric_name                = "stockspoon-api-per-source-ip"
      # Sampled requests do not respect logging redaction; avoid exposing cookies.
      sampled_requests_enabled = false
    }
  }

  visibility_config {
    cloudwatch_metrics_enabled = true
    metric_name                = "stockspoon-api-rate-limit"
    sampled_requests_enabled   = false
  }

  tags = {
    Project     = "stockspoon"
    Environment = "v2-prod"
    ManagedBy   = "Terraform"
  }
}

resource "aws_cloudwatch_log_group" "waf" {
  name              = "aws-waf-logs-stockspoon-api-rate-limit"
  retention_in_days = 14
}

resource "aws_wafv2_web_acl_logging_configuration" "api" {
  resource_arn            = aws_wafv2_web_acl.api.arn
  log_destination_configs = [aws_cloudwatch_log_group.waf.arn]

  redacted_fields {
    single_header { name = "cookie" }
  }
  redacted_fields {
    single_header { name = "authorization" }
  }
  redacted_fields {
    query_string {}
  }
}

output "web_acl_arn" {
  value = aws_wafv2_web_acl.api.arn
}

output "log_group_name" {
  value = aws_cloudwatch_log_group.waf.name
}
