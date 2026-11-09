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
  description = "Action for the api-per-source-ip rate rule only; managed SQLi and Linux groups retain their AWS actions."
  type        = string
  default     = "count"
  validation {
    condition     = contains(["count", "block"], var.mode)
    error_message = "mode must be count or block."
  }
}

locals {
  # Count all currently published rules individually so they emit per-rule metrics.
  # The enclosing Count override is a safety fallback: a newly added AWS rule
  # remains observational until its name and impact are reviewed.
  managed_rule_groups = [
    {
      name               = "managed-crs"
      managed_group_name = "AWSManagedRulesCommonRuleSet"
      metric_name        = "stockspoon-managed-crs"
      priority           = 0
      count_only         = true
      count_rule_names = [
        "NoUserAgent_HEADER",
        "UserAgent_BadBots_HEADER",
        "SizeRestrictions_QUERYSTRING",
        "SizeRestrictions_Cookie_HEADER",
        "SizeRestrictions_BODY",
        "SizeRestrictions_URIPATH",
        "EC2MetaDataSSRF_BODY",
        "EC2MetaDataSSRF_COOKIE",
        "EC2MetaDataSSRF_URIPATH",
        "EC2MetaDataSSRF_QUERYARGUMENTS",
        "GenericLFI_QUERYARGUMENTS",
        "GenericLFI_URIPATH",
        "GenericLFI_BODY",
        "RestrictedExtensions_URIPATH",
        "RestrictedExtensions_QUERYARGUMENTS",
        "GenericRFI_QUERYARGUMENTS",
        "GenericRFI_BODY",
        "GenericRFI_URIPATH",
        "CrossSiteScripting_COOKIE",
        "CrossSiteScripting_QUERYARGUMENTS",
        "CrossSiteScripting_BODY",
        "CrossSiteScripting_URIPATH",
      ]
    },
    {
      name               = "managed-known-bad-inputs"
      managed_group_name = "AWSManagedRulesKnownBadInputsRuleSet"
      metric_name        = "stockspoon-managed-known-bad-inputs"
      priority           = 1
      count_only         = true
      count_rule_names = [
        "JavaDeserializationRCE_BODY",
        "JavaDeserializationRCE_URIPATH",
        "JavaDeserializationRCE_QUERYSTRING",
        "JavaDeserializationRCE_HEADER",
        "Host_localhost_HEADER",
        "PROPFIND_METHOD",
        "ExploitablePaths_URIPATH",
        "Log4JRCE_QUERYSTRING",
        "Log4JRCE_BODY",
        "Log4JRCE_URIPATH",
        "Log4JRCE_HEADER",
        "ReactJSRCE_BODY",
      ]
    },
    {
      name               = "managed-admin-protection"
      managed_group_name = "AWSManagedRulesAdminProtectionRuleSet"
      metric_name        = "stockspoon-managed-admin-protection"
      priority           = 2
      count_only         = true
      count_rule_names   = ["AdminProtection_URIPATH"]
    },
    {
      name               = "managed-anonymous-ip-list"
      managed_group_name = "AWSManagedRulesAnonymousIpList"
      metric_name        = "stockspoon-managed-anonymous-ip-list"
      priority           = 3
      count_only         = true
      count_rule_names   = ["AnonymousIPList", "HostingProviderIPList"]
    },
    {
      name               = "managed-amazon-ip-reputation"
      managed_group_name = "AWSManagedRulesAmazonIpReputationList"
      metric_name        = "stockspoon-managed-amazon-ip-reputation"
      priority           = 4
      count_only         = true
      count_rule_names   = ["AWSManagedIPReputationList", "AWSManagedReconnaissanceList", "AWSManagedIPDDoSList"]
    },
    {
      name               = "managed-sqli"
      managed_group_name = "AWSManagedRulesSQLiRuleSet"
      metric_name        = "stockspoon-managed-sqli"
      priority           = 5
      count_only         = false
      count_rule_names   = []
    },
    {
      name               = "managed-linux"
      managed_group_name = "AWSManagedRulesLinuxRuleSet"
      metric_name        = "stockspoon-managed-linux"
      priority           = 6
      count_only         = false
      count_rule_names   = []
    },
  ]
}

# WAFv2 descriptions allow only letters, digits, spaces and + = : # @ / - , .
resource "aws_wafv2_web_acl" "api" {
  name        = "stockspoon-api-rate-limit"
  description = "CloudFront managed protections and API rate limit"
  scope       = "CLOUDFRONT"

  default_action {
    allow {}
  }

  # Count-only managed groups run before any terminating rule. SQLi and Linux
  # retain AWS's default blocking actions, but are ordered after the Count groups.
  dynamic "rule" {
    for_each = local.managed_rule_groups

    content {
      name     = rule.value.name
      priority = rule.value.priority

      override_action {
        dynamic "count" {
          for_each = rule.value.count_only ? [1] : []
          content {}
        }
        dynamic "none" {
          for_each = rule.value.count_only ? [] : [1]
          content {}
        }
      }

      statement {
        managed_rule_group_statement {
          name        = rule.value.managed_group_name
          vendor_name = "AWS"

          dynamic "rule_action_override" {
            for_each = rule.value.count_rule_names
            content {
              name = rule_action_override.value
              action_to_use {
                count {}
              }
            }
          }
        }
      }

      visibility_config {
        cloudwatch_metrics_enabled = true
        metric_name                = rule.value.metric_name
        sampled_requests_enabled   = false
      }
    }
  }

  rule {
    name     = "api-per-source-ip"
    priority = 7
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
