data "aws_caller_identity" "current" {}

data "aws_partition" "current" {}

locals {
  ai_alarm_prefix              = "stockspoon-v1-ai"
  ai_log_metric_namespace      = "Stockspoon/AI/Logs"
  ai_storage_metric_namespace  = "Stockspoon/AI/USE"
  ai_storage_error_metric_name = "StorageDeviceErrorCount"
  ai_application_error_metric  = "ErrorCount"
  ai_alarm_notifier_lambda_arn = aws_lambda_function.ai_discord_notifier.arn
  ai_alarm_tags = {
    Project     = "stockspoon"
    Environment = "v1"
    Server      = "ai"
    ManagedBy   = "Terraform"
  }
}

# AI 전용 Discord 알림 Lambda를 AI CloudWatch Alarm에서만 호출할 수 있도록 허용합니다.
resource "aws_lambda_permission" "ai_cloudwatch_alarms" {
  statement_id   = "AllowStockspoonAICloudWatchAlarms"
  action         = "lambda:InvokeFunction"
  function_name  = aws_lambda_function.ai_discord_notifier.function_name
  principal      = "lambda.alarms.cloudwatch.amazonaws.com"
  source_account = data.aws_caller_identity.current.account_id
  source_arn     = "arn:${data.aws_partition.current.partition}:cloudwatch:${var.aws_region}:${data.aws_caller_identity.current.account_id}:alarm:${local.ai_alarm_prefix}-*"
}

# AI 애플리케이션 로그에서 대소문자별 일반적인 오류 표기를 이벤트 단위로 집계합니다.
resource "aws_cloudwatch_log_metric_filter" "ai_application_errors" {
  name           = "${local.ai_alarm_prefix}-error-count"
  log_group_name = var.application_log_group
  pattern        = "?ERROR ?Error ?error"

  metric_transformation {
    name      = local.ai_application_error_metric
    namespace = local.ai_log_metric_namespace
    value     = "1"
    unit      = "Count"
  }
}

# 커널 로그에서 디스크 및 파일 시스템의 대표적인 장치 오류를 집계합니다.
resource "aws_cloudwatch_log_metric_filter" "ai_storage_errors" {
  name           = "${local.ai_alarm_prefix}-storage-errors"
  log_group_name = var.system_log_group
  pattern        = "?\"I/O error\" ?blk_update_request ?\"EXT4-fs error\" ?\"Buffer I/O error\" ?\"I/O timeout\" ?\"critical medium error\""

  metric_transformation {
    name      = local.ai_storage_error_metric_name
    namespace = local.ai_storage_metric_namespace
    value     = "1"
    unit      = "Count"
  }
}

resource "aws_cloudwatch_metric_alarm" "ai_cpu_high" {
  alarm_name          = "${local.ai_alarm_prefix}-cpu-high"
  alarm_description   = "AI host average CPU active is at least 85% for 3 of 5 one-minute periods."
  namespace           = local.namespace
  metric_name         = "cpu_usage_active"
  statistic           = "Average"
  period              = 60
  evaluation_periods  = 5
  datapoints_to_alarm = 3
  threshold           = 85
  comparison_operator = "GreaterThanOrEqualToThreshold"
  unit                = "Percent"
  treat_missing_data  = "notBreaching"
  alarm_actions       = [local.ai_alarm_notifier_lambda_arn]

  depends_on = [aws_lambda_permission.ai_cloudwatch_alarms]

  dimensions = {
    InstanceId   = var.ai_instance_id
    InstanceType = var.ai_instance_type
    cpu          = "cpu-total"
  }

  tags = local.ai_alarm_tags
}

resource "aws_cloudwatch_metric_alarm" "ai_memory_high" {
  alarm_name          = "${local.ai_alarm_prefix}-memory-used-high"
  alarm_description   = "AI host memory used is at least 85% for 3 of 5 one-minute periods."
  namespace           = local.namespace
  metric_name         = "mem_used_percent"
  statistic           = "Average"
  period              = 60
  evaluation_periods  = 5
  datapoints_to_alarm = 3
  threshold           = 85
  comparison_operator = "GreaterThanOrEqualToThreshold"
  unit                = "Percent"
  treat_missing_data  = "notBreaching"
  alarm_actions       = [local.ai_alarm_notifier_lambda_arn]

  depends_on = [aws_lambda_permission.ai_cloudwatch_alarms]

  dimensions = {
    InstanceId   = var.ai_instance_id
    InstanceType = var.ai_instance_type
  }

  tags = local.ai_alarm_tags
}

resource "aws_cloudwatch_metric_alarm" "ai_root_disk_high" {
  alarm_name          = "${local.ai_alarm_prefix}-root-disk-high"
  alarm_description   = "AI root filesystem usage is at least 85% for 5 consecutive one-minute periods."
  namespace           = local.namespace
  metric_name         = "disk_used_percent"
  statistic           = "Average"
  period              = 60
  evaluation_periods  = 5
  datapoints_to_alarm = 5
  threshold           = 85
  comparison_operator = "GreaterThanOrEqualToThreshold"
  unit                = "Percent"
  treat_missing_data  = "notBreaching"
  alarm_actions       = [local.ai_alarm_notifier_lambda_arn]

  depends_on = [aws_lambda_permission.ai_cloudwatch_alarms]

  dimensions = {
    InstanceId   = var.ai_instance_id
    InstanceType = var.ai_instance_type
    path         = "/"
    fstype       = "ext4"
  }

  tags = local.ai_alarm_tags
}

resource "aws_cloudwatch_metric_alarm" "ai_ec2_status_check_failed" {
  alarm_name          = "${local.ai_alarm_prefix}-ec2-status-check-failed"
  alarm_description   = "AI EC2 has failed a status check for 2 consecutive one-minute periods."
  namespace           = "AWS/EC2"
  metric_name         = "StatusCheckFailed"
  statistic           = "Maximum"
  period              = 60
  evaluation_periods  = 2
  datapoints_to_alarm = 2
  threshold           = 1
  comparison_operator = "GreaterThanOrEqualToThreshold"
  treat_missing_data  = "notBreaching"
  alarm_actions       = [local.ai_alarm_notifier_lambda_arn]

  depends_on = [aws_lambda_permission.ai_cloudwatch_alarms]

  dimensions = {
    InstanceId = var.ai_instance_id
  }

  tags = local.ai_alarm_tags
}

resource "aws_cloudwatch_metric_alarm" "ai_storage_device_error" {
  alarm_name          = "${local.ai_alarm_prefix}-storage-device-error"
  alarm_description   = "At least one AI storage-device error was logged in the last five minutes."
  namespace           = local.ai_storage_metric_namespace
  metric_name         = local.ai_storage_error_metric_name
  statistic           = "Sum"
  period              = 300
  evaluation_periods  = 1
  datapoints_to_alarm = 1
  threshold           = 1
  comparison_operator = "GreaterThanOrEqualToThreshold"
  unit                = "Count"
  treat_missing_data  = "notBreaching"
  alarm_actions       = [local.ai_alarm_notifier_lambda_arn]

  depends_on = [aws_lambda_permission.ai_cloudwatch_alarms]

  tags = local.ai_alarm_tags
}

resource "aws_cloudwatch_metric_alarm" "ai_application_log_errors" {
  alarm_name          = "${local.ai_alarm_prefix}-log-errors"
  alarm_description   = "At least five AI ERROR/Error/error log events were received in the last five minutes."
  namespace           = local.ai_log_metric_namespace
  metric_name         = local.ai_application_error_metric
  statistic           = "Sum"
  period              = 300
  evaluation_periods  = 1
  datapoints_to_alarm = 1
  threshold           = 5
  comparison_operator = "GreaterThanOrEqualToThreshold"
  unit                = "Count"
  treat_missing_data  = "notBreaching"
  alarm_actions       = [local.ai_alarm_notifier_lambda_arn]

  depends_on = [aws_lambda_permission.ai_cloudwatch_alarms]

  tags = local.ai_alarm_tags
}
