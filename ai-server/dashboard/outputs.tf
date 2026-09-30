# 생성된 AI 대시보드 이름을 출력합니다.
output "dashboard_name" {
  value = aws_cloudwatch_dashboard.ai_basic.dashboard_name
}

# 생성된 AI 대시보드의 AWS 콘솔 접속 주소를 출력합니다.
output "dashboard_url" {
  value = "https://${var.aws_region}.console.aws.amazon.com/cloudwatch/home?region=${var.aws_region}#dashboards:name=${aws_cloudwatch_dashboard.ai_basic.dashboard_name}"
}
