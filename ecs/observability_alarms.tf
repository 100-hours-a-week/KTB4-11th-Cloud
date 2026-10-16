locals {
  observed_targets = merge(
    { backend = aws_lb_target_group.backend_green.arn_suffix },
    local.ai_market_enabled ? { market-http = aws_lb_target_group.market_http.arn_suffix } : {},
  )
}

# 장애 감지용 알람. 자동 확장용 AlarmLow와 구분하며 FIS 중단 조건에서 참조할 수 있다.
resource "aws_cloudwatch_metric_alarm" "no_healthy_targets" {
  for_each = local.observed_targets

  alarm_name          = "${var.name_prefix}-${each.key}-no-healthy-targets"
  alarm_description   = "No healthy target for an actively registered ECS service; suitable as a FIS stop condition"
  namespace           = "AWS/ApplicationELB"
  metric_name         = "HealthyHostCount"
  dimensions          = { LoadBalancer = data.terraform_remote_state.app.outputs.alb_arn_suffix, TargetGroup = each.value }
  statistic           = "Minimum"
  period              = 60
  evaluation_periods  = 1
  comparison_operator = "LessThanThreshold"
  threshold           = 1
  treat_missing_data  = "breaching"
  alarm_actions       = var.observability_alarm_actions
  ok_actions          = var.observability_alarm_actions
}

resource "aws_cloudwatch_metric_alarm" "target_errors" {
  for_each = local.observed_targets

  alarm_name          = "${var.name_prefix}-${each.key}-target-5xx-rate"
  alarm_description   = "Target 5xx exceeds 5 percent with at least 20 requests/minute for 2 of 3 minutes"
  comparison_operator = "GreaterThanThreshold"
  threshold           = 5
  evaluation_periods  = 3
  datapoints_to_alarm = 2
  treat_missing_data  = "notBreaching"
  alarm_actions       = var.observability_alarm_actions
  ok_actions          = var.observability_alarm_actions

  metric_query {
    id          = "rate"
    expression  = "IF(requests>=20,100*FILL(errors,0)/requests,0)"
    label       = "Target 5xx percent"
    return_data = true
  }

  metric_query {
    id = "requests"
    metric {
      namespace   = "AWS/ApplicationELB"
      metric_name = "RequestCount"
      dimensions  = { LoadBalancer = data.terraform_remote_state.app.outputs.alb_arn_suffix, TargetGroup = each.value }
      period      = 60
      stat        = "Sum"
    }
  }

  metric_query {
    id = "errors"
    metric {
      namespace   = "AWS/ApplicationELB"
      metric_name = "HTTPCode_Target_5XX_Count"
      dimensions  = { LoadBalancer = data.terraform_remote_state.app.outputs.alb_arn_suffix, TargetGroup = each.value }
      period      = 60
      stat        = "Sum"
    }
  }
}
