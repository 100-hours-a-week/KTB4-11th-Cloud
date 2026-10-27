mock_provider "aws" {}

run "observe_all_api_paths" {
  command = plan
  assert {
    condition     = aws_wafv2_web_acl.api.scope == "CLOUDFRONT"
    error_message = "Count viewer IPs at CloudFront."
  }
  assert {
    # Mock providers skip AWS validation; mirror the WAFv2 description pattern.
    condition     = can(regex("^[\\w+=:#@/\\-,.][\\w+=:#@/\\-,.\\s]+[\\w+=:#@/\\-,.]$", aws_wafv2_web_acl.api.description))
    error_message = "WAFv2 descriptions reject characters such as ';'."
  }
  assert {
    condition     = length(aws_wafv2_web_acl.api.rule) == 1
    error_message = "No special users/me rule should exist."
  }
  assert {
    condition = alltrue([for r in aws_wafv2_web_acl.api.rule :
      length(r.action[0].count) == 1 && length(r.action[0].block) == 0 &&
      r.statement[0].rate_based_statement[0].aggregate_key_type == "IP" &&
      r.statement[0].rate_based_statement[0].limit == 500 &&
      r.statement[0].rate_based_statement[0].evaluation_window_sec == 300 &&
      r.statement[0].rate_based_statement[0].scope_down_statement[0].byte_match_statement[0].search_string == "/api/" &&
      r.statement[0].rate_based_statement[0].scope_down_statement[0].byte_match_statement[0].positional_constraint == "STARTS_WITH"
    ])
    error_message = "Default must count 500 requests per 300s per IP across /api/ paths."
  }
  assert {
    condition     = aws_cloudwatch_log_group.waf.retention_in_days == 14 && length(aws_wafv2_web_acl_logging_configuration.api.redacted_fields) == 3 && !aws_wafv2_web_acl.api.visibility_config[0].sampled_requests_enabled
    error_message = "Keep redacted logs, disable unredacted samples, and expire logs after 14 days."
  }
}

run "explicit_block_returns_429" {
  command = plan
  variables {
    mode = "block"
  }
  assert {
    condition = alltrue([for r in aws_wafv2_web_acl.api.rule :
      length(r.action[0].count) == 0 && r.action[0].block[0].custom_response[0].response_code == 429
    ])
    error_message = "Block mode must replace Count and return HTTP 429."
  }
}

run "one_minute_experiment" {
  command = plan
  variables {
    evaluation_window_sec = 60
    request_limit         = 120
  }
  assert {
    condition = alltrue([for r in aws_wafv2_web_acl.api.rule :
      r.statement[0].rate_based_statement[0].evaluation_window_sec == 60 && r.statement[0].rate_based_statement[0].limit == 120
    ])
    error_message = "Experimental limits and supported windows must be configurable."
  }
}

run "reject_invalid_mode" {
  command = plan
  variables { mode = "allow" }
  expect_failures = [var.mode]
}

run "reject_invalid_window" {
  command = plan
  variables { evaluation_window_sec = 30 }
  expect_failures = [var.evaluation_window_sec]
}

run "reject_invalid_limit" {
  command = plan
  variables { request_limit = 9 }
  expect_failures = [var.request_limit]
}
