locals {
  backend_rollback_widgets = flatten([for controller in aws_lambda_function.backend_rollback : [
    {
      type = "alarm", x = 0, y = 0, width = 24, height = 3
      properties = {
        title = "Backend routing rollback alarms (arm via SSM after checking V1)"
        alarms = [
          aws_cloudwatch_metric_alarm.backend_rollback_unhealthy[0].arn,
          aws_cloudwatch_metric_alarm.backend_rollback_errors[0].arn,
          aws_cloudwatch_metric_alarm.backend_rollback_controller_errors[0].arn,
        ]
      }
    },
    {
      type = "log", x = 0, y = 3, width = 24, height = 6
      properties = {
        title = "Backend routing rollback timeline", region = var.aws_region, view = "table"
        query = "SOURCE '${aws_cloudwatch_log_group.backend_rollback[0].name}' | fields @timestamp, action, alarms, weights, reason, @message | filter action like /rollback_/ or @message like /ERROR/ | sort @timestamp desc | limit 100"
      }
    },
    {
      type = "metric", x = 0, y = 9, width = 24, height = 6
      properties = {
        title = "Rollback controller failures / throttles / failed-event queue", region = var.aws_region, period = 60, stat = "Sum", view = "timeSeries"
        metrics = [
          ["AWS/Lambda", "Errors", "FunctionName", local.backend_rollback_name],
          ["AWS/Lambda", "Throttles", "FunctionName", local.backend_rollback_name],
          ["AWS/Lambda", "DeadLetterErrors", "FunctionName", local.backend_rollback_name],
          ["AWS/SQS", "ApproximateNumberOfMessagesVisible", "QueueName", aws_sqs_queue.backend_rollback_failures[0].name, { stat = "Maximum" }],
        ]
      }
    },
  ]])
}

resource "aws_cloudwatch_dashboard" "backend_rollback" {
  count          = local.backend_rollback_enabled ? 1 : 0
  dashboard_name = local.backend_rollback_name
  dashboard_body = jsonencode({
    start          = "-PT1H"
    periodOverride = "inherit"
    widgets = concat(local.backend_rollback_widgets, [{
      type = "metric", x = 0, y = 15, width = 24, height = 6
      properties = {
        title = "V1 / V2 requests and V2 target errors", region = var.aws_region, period = 60, stat = "Sum", view = "timeSeries"
        metrics = [
          ["AWS/ApplicationELB", "RequestCount", "LoadBalancer", data.terraform_remote_state.app.outputs.alb_arn_suffix, "TargetGroup", split(":", data.terraform_remote_state.app.outputs.blue_target_group_arn)[5], { label = "V1 requests" }],
          ["AWS/ApplicationELB", "RequestCount", "LoadBalancer", data.terraform_remote_state.app.outputs.alb_arn_suffix, "TargetGroup", aws_lb_target_group.backend_green.arn_suffix, { label = "V2 requests" }],
          ["AWS/ApplicationELB", "HTTPCode_Target_5XX_Count", "LoadBalancer", data.terraform_remote_state.app.outputs.alb_arn_suffix, "TargetGroup", aws_lb_target_group.backend_green.arn_suffix, { label = "V2 target 5xx" }],
        ]
      }
    }])
  })
}
