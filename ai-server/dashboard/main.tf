# AI 지표 네임스페이스와 대시보드 위젯 공통 설정을 정의합니다.
locals {
  namespace = "AI_CWAgent"

  widget_defaults = {
    region = var.aws_region
    width  = 12
    height = 6
    period = 60
    view   = "timeSeries"
  }
}

# AI 서버의 기본 시스템 지표를 표시하는 CloudWatch 대시보드를 생성합니다.
resource "aws_cloudwatch_dashboard" "ai_basic" {
  dashboard_name = var.dashboard_name

  dashboard_body = jsonencode({
    start          = "-PT3H"
    periodOverride = "inherit"
    widgets = [
      # AI 서버 전체 CPU의 평균 사용률을 표시합니다.
      {
        type = "metric"
        x    = 0
        y    = 0
        properties = merge(local.widget_defaults, {
          title = "AI CPU 사용률"
          stat  = "Average"
          yAxis = { left = { min = 0, max = 100 } }
          metrics = [
            [local.namespace, "cpu_usage_active", "InstanceId", var.ai_instance_id, "InstanceType", var.ai_instance_type, "cpu", "cpu-total", { label = "CPU active", color = "#d62728" }]
          ]
        })
      },
      # AI 서버의 메모리 사용률과 가용률을 함께 표시합니다.
      {
        type = "metric"
        x    = 12
        y    = 0
        properties = merge(local.widget_defaults, {
          title = "AI 메모리"
          stat  = "Average"
          yAxis = { left = { min = 0, max = 100 } }
          metrics = [
            [local.namespace, "mem_used_percent", "InstanceId", var.ai_instance_id, "InstanceType", var.ai_instance_type, { label = "사용", color = "#ff7f0e" }],
            [".", "mem_available_percent", ".", ".", ".", ".", { label = "가용", color = "#2ca02c" }]
          ]
        })
      },
      # AI 서버 루트 파일 시스템의 디스크 사용률을 표시합니다.
      {
        type = "metric"
        x    = 0
        y    = 6
        properties = merge(local.widget_defaults, {
          title = "AI 루트 디스크 사용률"
          stat  = "Average"
          yAxis = { left = { min = 0, max = 100 } }
          metrics = [
            [local.namespace, "disk_used_percent", "InstanceId", var.ai_instance_id, "InstanceType", var.ai_instance_type, "path", "/", "fstype", "ext4", { label = "/ 사용률", color = "#9467bd" }]
          ]
        })
      },
      # AI EC2 인스턴스의 네트워크 송수신량을 표시합니다.
      {
        type = "metric"
        x    = 12
        y    = 6
        properties = merge(local.widget_defaults, {
          title = "AI 네트워크 송수신"
          stat  = "Sum"
          metrics = [
            ["AWS/EC2", "NetworkIn", "InstanceId", var.ai_instance_id, { label = "수신", color = "#1f77b4" }],
            [".", "NetworkOut", ".", ".", { label = "송신", color = "#ff7f0e" }]
          ]
        })
      },
      # AI EC2 인스턴스와 기반 시스템의 상태 검사 실패 여부를 표시합니다.
      {
        type   = "metric"
        x      = 0
        y      = 12
        width  = 24
        height = 5
        properties = {
          title  = "AI EC2 상태 검사"
          region = var.aws_region
          view   = "timeSeries"
          stat   = "Maximum"
          period = 60
          yAxis  = { left = { min = 0, max = 1 } }
          metrics = [
            ["AWS/EC2", "StatusCheckFailed", "InstanceId", var.ai_instance_id, { label = "전체", color = "#d62728" }],
            [".", "StatusCheckFailed_Instance", ".", ".", { label = "인스턴스", color = "#ff7f0e" }],
            [".", "StatusCheckFailed_System", ".", ".", { label = "시스템", color = "#9467bd" }]
          ]
        }
      }
    ]
  })
}
