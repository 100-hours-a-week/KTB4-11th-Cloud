resource "aws_cloudwatch_metric_alarm" "ai_container_failure" {
  alarm_name          = "${local.ai_alarm_prefix}-container-failure"
  alarm_description   = "AI postgres or questdb is not running and healthy for two consecutive minutes, or the container monitor stopped reporting."
  namespace           = local.namespace
  metric_name         = "ContainerFailureCount"
  statistic           = "Maximum"
  period              = 60
  evaluation_periods  = 2
  datapoints_to_alarm = 2
  threshold           = 1
  comparison_operator = "GreaterThanOrEqualToThreshold"
  unit                = "Count"
  treat_missing_data  = "breaching"
  alarm_actions       = [local.ai_alarm_notifier_lambda_arn]
  ok_actions          = [local.ai_alarm_notifier_lambda_arn]

  dimensions = {
    InstanceId = var.ai_instance_id
  }

  depends_on = [aws_lambda_permission.ai_cloudwatch_alarms]

  tags = local.ai_alarm_tags
}
