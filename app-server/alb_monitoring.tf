# ALB 경로 장애 감지 알람. 기존 Discord 알림 Lambda를 재사용
# Lambda 호출 권한이 alarm:stockspoon-v1-app-* 로 제한되어 있으므로 알람 이름 접두어를 맞춘다.
# DNS 전환·롤백 시 정상화 시점을 확인할 수 있도록 복구(OK) 알림도 함께 보낸다.

locals {
  alb_alarm_dimensions = {
    LoadBalancer = aws_lb.app.arn_suffix
  }
  alb_blue_target_dimensions = {
    LoadBalancer = aws_lb.app.arn_suffix
    TargetGroup  = aws_lb_target_group.blue.arn_suffix
  }
}

# 정상 타깃이 0개 = ALB 경로로는 서비스 불가하므로 데이터가 없을 때도 이상으로 간주
resource "aws_cloudwatch_metric_alarm" "app_alb_healthy_hosts_low" {
  alarm_name          = "stockspoon-v1-app-alb-healthy-hosts-low"
  alarm_description   = "ALB blue target group has no healthy targets."
  namespace           = "AWS/ApplicationELB"
  metric_name         = "HealthyHostCount"
  statistic           = "Minimum"
  period              = 60
  evaluation_periods  = 1
  datapoints_to_alarm = 1
  threshold           = 1
  comparison_operator = "LessThanThreshold"
  treat_missing_data  = "breaching"
  alarm_actions       = [aws_lambda_function.app_discord_notifier.arn]
  ok_actions          = [aws_lambda_function.app_discord_notifier.arn]
  dimensions          = local.alb_blue_target_dimensions

  depends_on = [aws_lambda_permission.app_cloudwatch_alarms]

  tags = local.alb_tags
}

# ALB 자체가 만든 5xx (타깃 연결 실패, 타깃 없음 등), 정상 상태에서는 0이어야 한다.
resource "aws_cloudwatch_metric_alarm" "app_alb_elb_5xx" {
  alarm_name          = "stockspoon-v1-app-alb-elb-5xx"
  alarm_description   = "ALB generated at least one 5xx response in a one-minute period."
  namespace           = "AWS/ApplicationELB"
  metric_name         = "HTTPCode_ELB_5XX_Count"
  statistic           = "Sum"
  period              = 60
  evaluation_periods  = 1
  datapoints_to_alarm = 1
  threshold           = 1
  comparison_operator = "GreaterThanOrEqualToThreshold"
  treat_missing_data  = "notBreaching"
  alarm_actions       = [aws_lambda_function.app_discord_notifier.arn]
  ok_actions          = [aws_lambda_function.app_discord_notifier.arn]
  dimensions          = local.alb_alarm_dimensions

  depends_on = [aws_lambda_permission.app_cloudwatch_alarms]

  tags = local.alb_tags
}

# Nginx/Backend가 응답한 5xx.
# 트래픽이 적어 분당 건수 기준을 높이면 Backend가 완전히 중단돼도 감지하지 못한다.
# 건수는 1건 이상으로 두고, 단발성 오류는 "5분 중 2분 이상"으로 걸러낸다.
resource "aws_cloudwatch_metric_alarm" "app_alb_target_5xx" {
  alarm_name          = "stockspoon-v1-app-alb-target-5xx"
  alarm_description   = "Targets behind the ALB returned 5xx responses in at least 2 of the last 5 minutes."
  namespace           = "AWS/ApplicationELB"
  metric_name         = "HTTPCode_Target_5XX_Count"
  statistic           = "Sum"
  period              = 60
  evaluation_periods  = 5
  datapoints_to_alarm = 2
  threshold           = 1
  comparison_operator = "GreaterThanOrEqualToThreshold"
  treat_missing_data  = "notBreaching"
  alarm_actions       = [aws_lambda_function.app_discord_notifier.arn]
  ok_actions          = [aws_lambda_function.app_discord_notifier.arn]
  dimensions          = local.alb_blue_target_dimensions

  depends_on = [aws_lambda_permission.app_cloudwatch_alarms]

  tags = local.alb_tags
}

# ALB → EC2 Nginx TCP 연결 실패 (SG, Nginx 중단 등)
resource "aws_cloudwatch_metric_alarm" "app_alb_target_connection_error" {
  alarm_name          = "stockspoon-v1-app-alb-target-connection-error"
  alarm_description   = "ALB failed to connect to targets at least once in a one-minute period."
  namespace           = "AWS/ApplicationELB"
  metric_name         = "TargetConnectionErrorCount"
  statistic           = "Sum"
  period              = 60
  evaluation_periods  = 1
  datapoints_to_alarm = 1
  threshold           = 1
  comparison_operator = "GreaterThanOrEqualToThreshold"
  treat_missing_data  = "notBreaching"
  alarm_actions       = [aws_lambda_function.app_discord_notifier.arn]
  ok_actions          = [aws_lambda_function.app_discord_notifier.arn]
  dimensions          = local.alb_blue_target_dimensions

  depends_on = [aws_lambda_permission.app_cloudwatch_alarms]

  tags = local.alb_tags
}
