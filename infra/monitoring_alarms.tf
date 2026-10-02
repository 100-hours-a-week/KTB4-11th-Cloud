resource "aws_cloudwatch_metric_alarm" "app_cpu_high" {
  alarm_name          = "stockspoon-v1-app-cpu-high"
  alarm_description   = "Peak host CPU usage_active is at least 70% in a one-minute period."
  namespace           = "CWAgent"
  metric_name         = "used_percent"
  statistic           = "Maximum"
  period              = 60
  evaluation_periods  = 1
  datapoints_to_alarm = 1
  threshold           = 70
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
  alarm_description   = "Peak host memory used is at least 30% in a one-minute period."
  namespace           = "CWAgent"
  metric_name         = "mem_used_percent"
  statistic           = "Maximum"
  period              = 60
  evaluation_periods  = 1
  datapoints_to_alarm = 1
  threshold           = 30
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

resource "aws_cloudwatch_metric_alarm" "app_network_bytes_recv_high" {
  alarm_name          = "stockspoon-v1-app-network-bytes-recv-high"
  alarm_description   = "At least 785625087 bytes were received on ens5 in a one-minute period."
  namespace           = "CWAgent"
  metric_name         = "net_bytes_recv"
  statistic           = "Sum"
  period              = 60
  evaluation_periods  = 1
  datapoints_to_alarm = 1
  threshold           = 785625087
  comparison_operator = "GreaterThanOrEqualToThreshold"
  unit                = "Bytes"
  treat_missing_data  = "notBreaching"
  alarm_actions       = [aws_lambda_function.app_discord_notifier.arn]

  depends_on = [aws_lambda_permission.app_cloudwatch_alarms]

  dimensions = {
    InstanceId   = aws_instance.app.id
    InstanceType = var.ec2_instance_type
    interface    = "ens5"
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
