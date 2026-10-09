resource "aws_lambda_permission" "cloudwatch_alarms" {
  statement_id   = "AllowStockspoonV2${title(var.environment)}ValkeyCloudWatchAlarms"
  action         = "lambda:InvokeFunction"
  function_name  = aws_lambda_function.discord_notifier.function_name
  principal      = "lambda.alarms.cloudwatch.amazonaws.com"
  source_account = data.aws_caller_identity.current.account_id
  source_arn     = "arn:${data.aws_partition.current.partition}:cloudwatch:${var.aws_region}:${data.aws_caller_identity.current.account_id}:alarm:${local.alarm_prefix}-*"
}

resource "aws_cloudwatch_metric_alarm" "storage_usage_high" {
  alarm_name          = "${local.alarm_prefix}-storage-usage-high"
  alarm_description   = "The V2 ${var.environment} Valkey cache is using at least 75 percent of its configured storage maximum."
  namespace           = "AWS/ElastiCache"
  metric_name         = "BytesUsedForCache"
  statistic           = "Maximum"
  period              = 60
  evaluation_periods  = 1
  datapoints_to_alarm = 1
  threshold           = local.storage_alarm_threshold_bytes
  comparison_operator = "GreaterThanOrEqualToThreshold"
  treat_missing_data  = "notBreaching"
  alarm_actions       = [aws_lambda_function.discord_notifier.arn]

  dimensions = {
    clusterId = aws_elasticache_serverless_cache.valkey.name
  }

  depends_on = [aws_lambda_permission.cloudwatch_alarms]
}

resource "aws_cloudwatch_metric_alarm" "ecpu_usage_high" {
  alarm_name          = "${local.alarm_prefix}-ecpu-usage-high"
  alarm_description   = "The V2 ${var.environment} Valkey cache consumed at least 75 percent of its configured ECPU per-second maximum over one minute."
  namespace           = "AWS/ElastiCache"
  metric_name         = "ElastiCacheProcessingUnits"
  statistic           = "Sum"
  period              = 60
  evaluation_periods  = 1
  datapoints_to_alarm = 1
  threshold           = local.ecpu_alarm_threshold_per_min
  comparison_operator = "GreaterThanOrEqualToThreshold"
  treat_missing_data  = "notBreaching"
  alarm_actions       = [aws_lambda_function.discord_notifier.arn]

  dimensions = {
    clusterId = aws_elasticache_serverless_cache.valkey.name
  }

  depends_on = [aws_lambda_permission.cloudwatch_alarms]
}

resource "aws_cloudwatch_metric_alarm" "throttled_commands" {
  alarm_name          = "${local.alarm_prefix}-throttled-commands"
  alarm_description   = "The V2 ${var.environment} Valkey cache throttled at least one command during one minute."
  namespace           = "AWS/ElastiCache"
  metric_name         = "ThrottledCmds"
  statistic           = "Sum"
  period              = 60
  evaluation_periods  = 1
  datapoints_to_alarm = 1
  threshold           = 1
  comparison_operator = "GreaterThanOrEqualToThreshold"
  treat_missing_data  = "notBreaching"
  alarm_actions       = [aws_lambda_function.discord_notifier.arn]

  dimensions = {
    clusterId = aws_elasticache_serverless_cache.valkey.name
  }

  depends_on = [aws_lambda_permission.cloudwatch_alarms]
}
