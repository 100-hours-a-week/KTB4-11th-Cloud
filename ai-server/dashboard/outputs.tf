# 생성된 AI 대시보드 이름을 출력합니다.
output "dashboard_name" {
  value = aws_cloudwatch_dashboard.ai_basic.dashboard_name
}

# 생성된 AI 대시보드의 AWS 콘솔 접속 주소를 출력합니다.
output "dashboard_url" {
  value = "https://${var.aws_region}.console.aws.amazon.com/cloudwatch/home?region=${var.aws_region}#dashboards:name=${aws_cloudwatch_dashboard.ai_basic.dashboard_name}"
}

# 생성되는 AI 장애 알람 이름을 배포 후 확인할 수 있도록 출력합니다.
output "alarm_names" {
  value = [
    aws_cloudwatch_metric_alarm.ai_cpu_high.alarm_name,
    aws_cloudwatch_metric_alarm.ai_metrics_missing.alarm_name,
    aws_cloudwatch_metric_alarm.ai_memory_high.alarm_name,
    aws_cloudwatch_metric_alarm.ai_root_disk_high.alarm_name,
    aws_cloudwatch_metric_alarm.ai_ec2_status_check_failed.alarm_name,
    aws_cloudwatch_metric_alarm.ai_storage_device_error.alarm_name,
    aws_cloudwatch_metric_alarm.ai_application_log_errors.alarm_name,
  ]
}

# 최초 배포 후 새 AI Discord Webhook URL을 저장할 Secret 이름을 출력합니다.
output "ai_discord_webhook_secret_name" {
  value = aws_secretsmanager_secret.ai_discord_webhook.name
}
