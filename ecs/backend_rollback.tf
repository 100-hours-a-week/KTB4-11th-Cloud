# The latch is shared deliberately: Terraform creates it; operators/Lambda set its value.
# A fresh refresh/plan observes tripped and keeps V1=100 even when desired V2=100.
locals {
  backend_rollback_enabled = var.backend_auto_rollback_enabled && var.backend_canary_enabled
  backend_rollback_name    = "${var.name_prefix}-backend-rollback"
  backend_rollback_path    = "/stockspoon/operations/prod/backend-routing/rollback-latch"
  backend_effective_green_weight = local.backend_rollback_enabled ? (
    nonsensitive(aws_ssm_parameter.backend_rollback[0].value) == "tripped" ? 0 : var.backend_canary_green_weight
  ) : var.backend_canary_green_weight
  backend_rollback_alarms = local.backend_rollback_enabled ? [
    aws_cloudwatch_metric_alarm.backend_rollback_unhealthy[0].alarm_name,
    aws_cloudwatch_metric_alarm.backend_rollback_errors[0].alarm_name,
  ] : []
}

variable "backend_auto_rollback_enabled" {
  description = "Provision rollback controller. Initially disarmed; arm through its SSM latch after checking V1."
  type        = bool
  default     = true
}

resource "aws_ssm_parameter" "backend_rollback" {
  count = local.backend_rollback_enabled ? 1 : 0
  name  = local.backend_rollback_path
  type  = "String"
  value = "disarmed"
  lifecycle {
    ignore_changes = [value]
    postcondition {
      condition     = contains(["disarmed", "armed", "tripped"], nonsensitive(self.value))
      error_message = "Invalid rollback latch value; restore disarmed, armed or tripped before planning."
    }
  }
}

resource "aws_cloudwatch_metric_alarm" "backend_rollback_unhealthy" {
  count               = local.backend_rollback_enabled ? 1 : 0
  alarm_name          = "${local.backend_rollback_name}-unhealthy"
  alarm_description   = "Rollback: no healthy V2 target in two consecutive one-minute periods"
  namespace           = "AWS/ApplicationELB"
  metric_name         = "HealthyHostCount"
  dimensions          = { LoadBalancer = data.terraform_remote_state.app.outputs.alb_arn_suffix, TargetGroup = aws_lb_target_group.backend_green.arn_suffix }
  statistic           = "Maximum"
  period              = 60
  evaluation_periods  = 2
  datapoints_to_alarm = 2
  comparison_operator = "LessThanThreshold"
  threshold           = 1
  treat_missing_data  = "notBreaching"
  alarm_actions       = var.observability_alarm_actions
}

resource "aws_cloudwatch_metric_alarm" "backend_rollback_errors" {
  count               = local.backend_rollback_enabled ? 1 : 0
  alarm_name          = "${local.backend_rollback_name}-5xx"
  alarm_description   = "Rollback: target 5xx >5%, >=5 requests and >=3 errors/minute for two consecutive minutes"
  comparison_operator = "GreaterThanThreshold"
  threshold           = 5
  evaluation_periods  = 2
  datapoints_to_alarm = 2
  treat_missing_data  = "notBreaching"
  alarm_actions       = var.observability_alarm_actions
  metric_query {
    id          = "rate"
    expression  = "IF(requests>=5,IF(FILL(errors,0)>=3,100*FILL(errors,0)/requests,0),0)"
    return_data = true
  }
  metric_query {
    id = "requests"
    metric {
      namespace   = "AWS/ApplicationELB"
      metric_name = "RequestCount"
      dimensions  = { LoadBalancer = data.terraform_remote_state.app.outputs.alb_arn_suffix, TargetGroup = aws_lb_target_group.backend_green.arn_suffix }
      period      = 60
      stat        = "Sum"
    }
  }
  metric_query {
    id = "errors"
    metric {
      namespace   = "AWS/ApplicationELB"
      metric_name = "HTTPCode_Target_5XX_Count"
      dimensions  = { LoadBalancer = data.terraform_remote_state.app.outputs.alb_arn_suffix, TargetGroup = aws_lb_target_group.backend_green.arn_suffix }
      period      = 60
      stat        = "Sum"
    }
  }
}

resource "aws_cloudwatch_event_rule" "backend_rollback_alarm" {
  count = local.backend_rollback_enabled ? 1 : 0
  name  = "${local.backend_rollback_name}-alarm"
  event_pattern = jsonencode({
    source        = ["aws.cloudwatch"]
    "detail-type" = ["CloudWatch Alarm State Change"]
    resources     = [aws_cloudwatch_metric_alarm.backend_rollback_unhealthy[0].arn, aws_cloudwatch_metric_alarm.backend_rollback_errors[0].arn]
    detail        = { state = { value = ["ALARM"] } }
  })
}

# Reconcile failed/delayed deliveries and reassert V1 after a stale saved plan.
resource "aws_cloudwatch_event_rule" "backend_rollback_reconcile" {
  count               = local.backend_rollback_enabled ? 1 : 0
  name                = "${local.backend_rollback_name}-reconcile"
  schedule_expression = "rate(1 minute)"
}

resource "aws_cloudwatch_log_group" "backend_rollback" {
  count             = local.backend_rollback_enabled ? 1 : 0
  name              = "/aws/lambda/${local.backend_rollback_name}"
  retention_in_days = 30
}

resource "aws_sqs_queue" "backend_rollback_failures" {
  count                     = local.backend_rollback_enabled ? 1 : 0
  name                      = "${local.backend_rollback_name}-failures"
  message_retention_seconds = 1209600
  sqs_managed_sse_enabled   = true
}

resource "aws_iam_role" "backend_rollback" {
  count = local.backend_rollback_enabled ? 1 : 0
  name  = local.backend_rollback_name
  assume_role_policy = jsonencode({
    Version   = "2012-10-17"
    Statement = [{ Effect = "Allow", Principal = { Service = "lambda.amazonaws.com" }, Action = "sts:AssumeRole" }]
  })
}

resource "aws_iam_role_policy" "backend_rollback" {
  count = local.backend_rollback_enabled ? 1 : 0
  name  = local.backend_rollback_name
  role  = aws_iam_role.backend_rollback[0].id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      { Effect = "Allow", Action = ["elasticloadbalancing:DescribeRules", "elasticloadbalancing:DescribeTargetHealth"], Resource = "*" },
      { Effect = "Allow", Action = ["elasticloadbalancing:ModifyRule"], Resource = aws_lb_listener_rule.backend_canary[0].arn },
      { Effect = "Allow", Action = ["ssm:GetParameter", "ssm:PutParameter"], Resource = aws_ssm_parameter.backend_rollback[0].arn },
      { Effect = "Allow", Action = ["cloudwatch:DescribeAlarms"], Resource = [aws_cloudwatch_metric_alarm.backend_rollback_unhealthy[0].arn, aws_cloudwatch_metric_alarm.backend_rollback_errors[0].arn] },
      { Effect = "Allow", Action = ["logs:CreateLogStream", "logs:PutLogEvents"], Resource = "${aws_cloudwatch_log_group.backend_rollback[0].arn}:*" },
      { Effect = "Allow", Action = ["sqs:SendMessage"], Resource = aws_sqs_queue.backend_rollback_failures[0].arn },
    ]
  })
}

data "archive_file" "backend_rollback" {
  count       = local.backend_rollback_enabled ? 1 : 0
  type        = "zip"
  source_file = "${path.module}/lambda/backend_rollback.py"
  output_path = "${path.module}/.terraform/backend-rollback.zip"
}

resource "aws_lambda_function" "backend_rollback" {
  count                          = local.backend_rollback_enabled ? 1 : 0
  function_name                  = local.backend_rollback_name
  role                           = aws_iam_role.backend_rollback[0].arn
  runtime                        = "python3.12"
  handler                        = "backend_rollback.handler"
  filename                       = data.archive_file.backend_rollback[0].output_path
  source_code_hash               = data.archive_file.backend_rollback[0].output_base64sha256
  timeout                        = 45
  memory_size                    = 128
  reserved_concurrent_executions = 1
  dead_letter_config {
    target_arn = aws_sqs_queue.backend_rollback_failures[0].arn
  }
  environment {
    variables = {
      ACCOUNT_ID          = local.account_id
      RULE_ARN            = aws_lb_listener_rule.backend_canary[0].arn
      V1_TARGET_GROUP_ARN = data.terraform_remote_state.app.outputs.blue_target_group_arn
      V2_TARGET_GROUP_ARN = aws_lb_target_group.backend_green.arn
      LATCH_PARAMETER     = aws_ssm_parameter.backend_rollback[0].name
      ALARM_NAMES         = jsonencode(local.backend_rollback_alarms)
      SCHEDULE_ARN        = aws_cloudwatch_event_rule.backend_rollback_reconcile[0].arn
    }
  }
  depends_on = [aws_iam_role_policy.backend_rollback]
}

resource "aws_lambda_function_event_invoke_config" "backend_rollback" {
  count                        = local.backend_rollback_enabled ? 1 : 0
  function_name                = aws_lambda_function.backend_rollback[0].function_name
  maximum_event_age_in_seconds = 300
  maximum_retry_attempts       = 2
}

locals {
  backend_rollback_rules = local.backend_rollback_enabled ? {
    alarm     = aws_cloudwatch_event_rule.backend_rollback_alarm[0]
    reconcile = aws_cloudwatch_event_rule.backend_rollback_reconcile[0]
  } : {}
}

resource "aws_lambda_permission" "backend_rollback" {
  for_each       = local.backend_rollback_rules
  statement_id   = "AllowEventBridge-${each.key}"
  action         = "lambda:InvokeFunction"
  function_name  = aws_lambda_function.backend_rollback[0].function_name
  principal      = "events.amazonaws.com"
  source_arn     = each.value.arn
  source_account = local.account_id
}

resource "aws_sqs_queue_policy" "backend_rollback_failures" {
  count     = local.backend_rollback_enabled ? 1 : 0
  queue_url = aws_sqs_queue.backend_rollback_failures[0].url
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "events.amazonaws.com" }
      Action    = "sqs:SendMessage"
      Resource  = aws_sqs_queue.backend_rollback_failures[0].arn
      Condition = { ArnEquals = { "aws:SourceArn" = [for rule in values(local.backend_rollback_rules) : rule.arn] } }
    }]
  })
}

resource "aws_cloudwatch_event_target" "backend_rollback" {
  for_each = local.backend_rollback_rules
  rule     = each.value.name
  arn      = aws_lambda_function.backend_rollback[0].arn
  dead_letter_config {
    arn = aws_sqs_queue.backend_rollback_failures[0].arn
  }
  retry_policy {
    maximum_event_age_in_seconds = 300
    maximum_retry_attempts       = 3
  }
  depends_on = [aws_lambda_permission.backend_rollback, aws_sqs_queue_policy.backend_rollback_failures]
}

resource "aws_cloudwatch_metric_alarm" "backend_rollback_controller_errors" {
  count               = local.backend_rollback_enabled ? 1 : 0
  alarm_name          = "${local.backend_rollback_name}-controller-errors"
  alarm_description   = "Rollback controller failed; inspect its logs and failure queue"
  namespace           = "AWS/Lambda"
  metric_name         = "Errors"
  dimensions          = { FunctionName = aws_lambda_function.backend_rollback[0].function_name }
  statistic           = "Sum"
  period              = 60
  evaluation_periods  = 1
  comparison_operator = "GreaterThanThreshold"
  threshold           = 0
  treat_missing_data  = "notBreaching"
  alarm_actions       = var.observability_alarm_actions
}

output "backend_auto_rollback" {
  value = local.backend_rollback_enabled ? {
    function_name   = aws_lambda_function.backend_rollback[0].function_name
    latch_parameter = aws_ssm_parameter.backend_rollback[0].name
    latch_state     = nonsensitive(aws_ssm_parameter.backend_rollback[0].value)
    alarms          = local.backend_rollback_alarms
    log_group       = aws_cloudwatch_log_group.backend_rollback[0].name
    failure_queue   = aws_sqs_queue.backend_rollback_failures[0].url
    dashboard_url   = "https://${var.aws_region}.console.aws.amazon.com/cloudwatch/home?region=${var.aws_region}#dashboards/dashboard/${aws_cloudwatch_dashboard.backend_rollback[0].dashboard_name}"
  } : null
}
