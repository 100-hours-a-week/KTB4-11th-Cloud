locals {
  app_log_metric_namespace = "Stockspoon/Logs"
  app_log_error_services = {
    nginx = {
      metric_name = "NginxErrorCount"
      pattern     = "?\"[error]\" ?\"[crit]\" ?\"[alert]\" ?\"[emerg]\""
    }
    frontend = {
      metric_name = "FrontendErrorCount"
      pattern     = "?ERROR ?Error ?error"
    }
    backend = {
      metric_name = "BackendErrorCount"
      pattern     = "?ERROR ?Error ?error"
    }
    db = {
      metric_name = "DatabaseErrorCount"
      pattern     = "?ERROR ?Error ?error"
    }
  }
}

# Keep the aggregate filter during migration so old containers continue to
# alert until they have been recreated with service-specific log groups.
resource "aws_cloudwatch_log_metric_filter" "app_errors" {
  name           = "stockspoon-v1-app-error-count"
  log_group_name = aws_cloudwatch_log_group.app_containers.name
  pattern        = "?ERROR ?Error ?error"

  metric_transformation {
    name      = "ErrorCount"
    namespace = local.app_log_metric_namespace
    value     = "1"
    unit      = "Count"
  }
}

# The Nginx filter matches its bracketed severity field; application
# containers use common text levels.
resource "aws_cloudwatch_log_metric_filter" "app_service_errors" {
  for_each = local.app_log_error_services

  name           = "stockspoon-v1-app-${each.key}-error-count"
  log_group_name = aws_cloudwatch_log_group.app_container_services[each.key].name
  pattern        = each.value.pattern

  metric_transformation {
    name      = each.value.metric_name
    namespace = local.app_log_metric_namespace
    value     = "1"
    unit      = "Count"
  }
}

resource "aws_cloudwatch_log_metric_filter" "app_nginx_http_5xx" {
  name           = "stockspoon-v1-app-nginx-http-5xx"
  log_group_name = aws_cloudwatch_log_group.app_container_services["nginx"].name
  pattern        = "{ $.status >= 500 && $.status < 600 }"

  metric_transformation {
    name      = "NginxHttp5xxCount"
    namespace = local.app_log_metric_namespace
    value     = "1"
    unit      = "Count"
  }
}

resource "aws_cloudwatch_metric_alarm" "app_cpu_high" {
  alarm_name          = "stockspoon-v1-app-cpu-high"
  alarm_description   = "Average host CPU active is at least 85% for 3 of 5 one-minute periods."
  namespace           = "CWAgent"
  metric_name         = "cpu_usage_active"
  statistic           = "Average"
  period              = 60
  evaluation_periods  = 5
  datapoints_to_alarm = 3
  threshold           = 85
  comparison_operator = "GreaterThanOrEqualToThreshold"
  unit                = "Percent"
  treat_missing_data  = "notBreaching"
  alarm_actions       = [aws_lambda_function.app_discord_notifier.arn]

  depends_on = [aws_lambda_permission.app_cloudwatch_alarms]

  dimensions = {
    InstanceId   = aws_instance.app.id
    InstanceType = var.ec2_instance_type
    cpu          = "cpu-total"
  }

  tags = {
    Project     = "stockspoon"
    Environment = "v1"
    ManagedBy   = "Terraform"
  }
}

resource "aws_cloudwatch_metric_alarm" "app_memory_low" {
  alarm_name          = "stockspoon-v1-app-memory-used-high"
  alarm_description   = "Host memory used is at least 85% for 3 of 5 one-minute periods."
  namespace           = "CWAgent"
  metric_name         = "mem_used_percent"
  statistic           = "Average"
  period              = 60
  evaluation_periods  = 5
  datapoints_to_alarm = 3
  threshold           = 85
  comparison_operator = "GreaterThanOrEqualToThreshold"
  unit                = "Percent"
  treat_missing_data  = "notBreaching"
  alarm_actions       = [aws_lambda_function.app_discord_notifier.arn]

  depends_on = [aws_lambda_permission.app_cloudwatch_alarms]

  dimensions = {
    InstanceId   = aws_instance.app.id
    InstanceType = var.ec2_instance_type
  }

  tags = {
    Project     = "stockspoon"
    Environment = "v1"
    ManagedBy   = "Terraform"
  }
}

resource "aws_cloudwatch_metric_alarm" "app_root_disk_high" {
  alarm_name          = "stockspoon-v1-app-root-disk-high"
  alarm_description   = "Root filesystem usage is at least 85% for 5 consecutive one-minute periods."
  namespace           = "CWAgent"
  metric_name         = "disk_used_percent"
  statistic           = "Average"
  period              = 60
  evaluation_periods  = 5
  datapoints_to_alarm = 5
  threshold           = 85
  comparison_operator = "GreaterThanOrEqualToThreshold"
  unit                = "Percent"
  treat_missing_data  = "notBreaching"
  alarm_actions       = [aws_lambda_function.app_discord_notifier.arn]

  depends_on = [aws_lambda_permission.app_cloudwatch_alarms]

  # The configured Ubuntu root filesystem is expected to be ext4. Confirm
  # with `df -T /` on the instance if this alarm does not receive datapoints.
  dimensions = {
    InstanceId   = aws_instance.app.id
    InstanceType = var.ec2_instance_type
    path         = "/"
    fstype       = "ext4"
  }

  tags = {
    Project     = "stockspoon"
    Environment = "v1"
    ManagedBy   = "Terraform"
  }
}

resource "aws_cloudwatch_metric_alarm" "app_ec2_status_check_failed" {
  alarm_name          = "stockspoon-v1-app-ec2-status-check-failed"
  alarm_description   = "EC2 has failed a status check for 2 consecutive one-minute periods."
  namespace           = "AWS/EC2"
  metric_name         = "StatusCheckFailed"
  statistic           = "Maximum"
  period              = 60
  evaluation_periods  = 2
  datapoints_to_alarm = 2
  threshold           = 1
  comparison_operator = "GreaterThanOrEqualToThreshold"
  treat_missing_data  = "notBreaching"
  alarm_actions       = [aws_lambda_function.app_discord_notifier.arn]

  depends_on = [aws_lambda_permission.app_cloudwatch_alarms]

  dimensions = {
    InstanceId = aws_instance.app.id
  }

  tags = {
    Project     = "stockspoon"
    Environment = "v1"
    ManagedBy   = "Terraform"
  }
}

resource "aws_cloudwatch_metric_alarm" "app_storage_device_error" {
  alarm_name          = "stockspoon-v1-app-storage-device-error"
  alarm_description   = "At least one known storage-device error was logged in the last five minutes."
  namespace           = "Stockspoon/USE"
  metric_name         = "StorageDeviceErrorCount"
  statistic           = "Sum"
  period              = 300
  evaluation_periods  = 1
  datapoints_to_alarm = 1
  threshold           = 1
  comparison_operator = "GreaterThanOrEqualToThreshold"
  unit                = "Count"
  treat_missing_data  = "notBreaching"
  alarm_actions       = [aws_lambda_function.app_discord_notifier.arn]

  depends_on = [aws_lambda_permission.app_cloudwatch_alarms]

  tags = {
    Project     = "stockspoon"
    Environment = "v1"
    ManagedBy   = "Terraform"
  }
}

resource "aws_cloudwatch_metric_alarm" "app_log_errors" {
  alarm_name          = "stockspoon-v1-app-log-errors"
  alarm_description   = "At least five ERROR/Error/error log events were received in the legacy aggregate group during migration."
  namespace           = local.app_log_metric_namespace
  metric_name         = "ErrorCount"
  statistic           = "Sum"
  period              = 300
  evaluation_periods  = 1
  datapoints_to_alarm = 1
  threshold           = 5
  comparison_operator = "GreaterThanOrEqualToThreshold"
  unit                = "Count"
  treat_missing_data  = "notBreaching"
  alarm_actions       = [aws_lambda_function.app_discord_notifier.arn]

  depends_on = [aws_lambda_permission.app_cloudwatch_alarms]

  tags = {
    Project     = "stockspoon"
    Environment = "v1"
    ManagedBy   = "Terraform"
  }
}

resource "aws_cloudwatch_metric_alarm" "app_service_log_errors" {
  for_each = local.app_log_error_services

  alarm_name          = "stockspoon-v1-app-${each.key}-log-errors"
  alarm_description   = "At least five ${each.key} error log events were received in the last five minutes."
  namespace           = local.app_log_metric_namespace
  metric_name         = each.value.metric_name
  statistic           = "Sum"
  period              = 300
  evaluation_periods  = 1
  datapoints_to_alarm = 1
  threshold           = 5
  comparison_operator = "GreaterThanOrEqualToThreshold"
  unit                = "Count"
  treat_missing_data  = "notBreaching"
  alarm_actions       = [aws_lambda_function.app_discord_notifier.arn]

  depends_on = [aws_lambda_permission.app_cloudwatch_alarms]

  tags = {
    Project     = "stockspoon"
    Environment = "v1"
    ManagedBy   = "Terraform"
  }
}

resource "aws_cloudwatch_metric_alarm" "app_nginx_http_5xx" {
  alarm_name          = "stockspoon-v1-app-nginx-http-5xx"
  alarm_description   = "At least one HTTP 5xx response was returned by Nginx in the last five minutes."
  namespace           = local.app_log_metric_namespace
  metric_name         = "NginxHttp5xxCount"
  statistic           = "Sum"
  period              = 300
  evaluation_periods  = 1
  datapoints_to_alarm = 1
  threshold           = 1
  comparison_operator = "GreaterThanOrEqualToThreshold"
  unit                = "Count"
  treat_missing_data  = "notBreaching"
  alarm_actions       = [aws_lambda_function.app_discord_notifier.arn]

  depends_on = [aws_lambda_permission.app_cloudwatch_alarms]

  tags = {
    Project     = "stockspoon"
    Environment = "v1"
    ManagedBy   = "Terraform"
  }
}
