locals {
  ai_scheduled_jobs = toset([
    "market-collector",
    "news-preprocessor",
    "market-syncer",
    "morning-pipeline",
    "portfolio-rebalancer",
  ])
}

resource "aws_cloudwatch_metric_alarm" "ai_scheduled_job_failure" {
  for_each = local.ai_scheduled_jobs

  alarm_name          = "${local.ai_alarm_prefix}-scheduled-job-${each.key}-failure"
  alarm_description   = "AI scheduled job ${each.key} failed after exhausting its systemd retries."
  namespace           = local.namespace
  metric_name         = "ScheduledJobFailure"
  statistic           = "Maximum"
  period              = 60
  evaluation_periods  = 1
  datapoints_to_alarm = 1
  threshold           = 1
  comparison_operator = "GreaterThanOrEqualToThreshold"
  unit                = "Count"
  treat_missing_data  = "ignore"
  alarm_actions       = [local.ai_alarm_notifier_lambda_arn]
  ok_actions          = [local.ai_alarm_notifier_lambda_arn]

  dimensions = {
    InstanceId = var.ai_instance_id
    JobName    = each.key
  }

  depends_on = [aws_lambda_permission.ai_cloudwatch_alarms]

  tags = local.ai_alarm_tags
}
