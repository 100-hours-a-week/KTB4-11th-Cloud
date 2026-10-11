# ALB 요청 흐름 대시보드 (RED: Rate · Errors · Duration).
# EC2 호스트 자원(USE)은 stockspoon-v1-app-use, 요청 단위 지표는 이 대시보드에서 본다.
# ECS 전환 시 Green Target Group 위젯을 나란히 추가해 Canary 비율 전환을 확인한다.

locals {
  alb_dashboard_lb = aws_lb.app.arn_suffix
  alb_dashboard_tg = aws_lb_target_group.blue.arn_suffix
}

resource "aws_cloudwatch_dashboard" "alb" {
  dashboard_name = "stockspoon-v1-app-alb"

  dashboard_body = jsonencode({
    widgets = [
      {
        type   = "text"
        x      = 0
        y      = 0
        width  = 24
        height = 2
        properties = {
          markdown = "# Stockspoon V1 · ALB RED\n요청 수(Rate)·에러(Errors)·응답시간(Duration)을 봅니다. DNS 전환 시 RequestCount 증가와 에러·지연 변화를 함께 확인합니다. 호스트 자원은 `stockspoon-v1-app-use`를 봅니다."
        }
      },
      {
        type   = "alarm"
        x      = 0
        y      = 2
        width  = 24
        height = 3
        properties = {
          title = "ALB alarms"
          alarms = [
            aws_cloudwatch_metric_alarm.app_alb_healthy_hosts_low.arn,
            aws_cloudwatch_metric_alarm.app_alb_elb_5xx.arn,
            aws_cloudwatch_metric_alarm.app_alb_target_5xx.arn,
            aws_cloudwatch_metric_alarm.app_alb_target_connection_error.arn,
          ]
        }
      },

      # ---------------- Rate / Errors ----------------
      {
        type   = "metric"
        x      = 0
        y      = 5
        width  = 8
        height = 6
        properties = {
          title   = "Requests · per minute"
          view    = "timeSeries"
          stacked = false
          region  = var.aws_region
          period  = 60
          yAxis   = { left = { min = 0 } }
          metrics = [
            ["AWS/ApplicationELB", "RequestCount", "LoadBalancer", local.alb_dashboard_lb, { stat = "Sum", label = "ALB requests" }],
            ["AWS/ApplicationELB", "HTTPCode_Target_2XX_Count", "LoadBalancer", local.alb_dashboard_lb, "TargetGroup", local.alb_dashboard_tg, { stat = "Sum", label = "Target 2xx (blue)" }],
            ["AWS/ApplicationELB", "HTTPCode_Target_3XX_Count", "LoadBalancer", local.alb_dashboard_lb, "TargetGroup", local.alb_dashboard_tg, { stat = "Sum", label = "Target 3xx (blue)" }],
          ]
        }
      },
      {
        type   = "metric"
        x      = 8
        y      = 5
        width  = 8
        height = 6
        properties = {
          title   = "5xx · ALB vs Target"
          view    = "timeSeries"
          stacked = false
          region  = var.aws_region
          period  = 60
          yAxis   = { left = { min = 0 } }
          metrics = [
            ["AWS/ApplicationELB", "HTTPCode_ELB_5XX_Count", "LoadBalancer", local.alb_dashboard_lb, { stat = "Sum", label = "ALB 5xx" }],
            ["AWS/ApplicationELB", "HTTPCode_Target_5XX_Count", "LoadBalancer", local.alb_dashboard_lb, "TargetGroup", local.alb_dashboard_tg, { stat = "Sum", label = "Target 5xx (blue)" }],
          ]
        }
      },
      {
        type   = "metric"
        x      = 16
        y      = 5
        width  = 8
        height = 6
        properties = {
          title   = "4xx · ALB vs Target"
          view    = "timeSeries"
          stacked = false
          region  = var.aws_region
          period  = 60
          yAxis   = { left = { min = 0 } }
          metrics = [
            ["AWS/ApplicationELB", "HTTPCode_ELB_4XX_Count", "LoadBalancer", local.alb_dashboard_lb, { stat = "Sum", label = "ALB 4xx" }],
            ["AWS/ApplicationELB", "HTTPCode_Target_4XX_Count", "LoadBalancer", local.alb_dashboard_lb, "TargetGroup", local.alb_dashboard_tg, { stat = "Sum", label = "Target 4xx (blue)" }],
          ]
        }
      },

      # ---------------- Duration / Health ----------------
      {
        type   = "metric"
        x      = 0
        y      = 11
        width  = 12
        height = 6
        properties = {
          title   = "Target response time · seconds"
          view    = "timeSeries"
          stacked = false
          region  = var.aws_region
          period  = 60
          yAxis   = { left = { min = 0 } }
          metrics = [
            ["AWS/ApplicationELB", "TargetResponseTime", "LoadBalancer", local.alb_dashboard_lb, "TargetGroup", local.alb_dashboard_tg, { stat = "p50", label = "p50" }],
            ["AWS/ApplicationELB", "TargetResponseTime", "LoadBalancer", local.alb_dashboard_lb, "TargetGroup", local.alb_dashboard_tg, { stat = "p95", label = "p95" }],
            ["AWS/ApplicationELB", "TargetResponseTime", "LoadBalancer", local.alb_dashboard_lb, "TargetGroup", local.alb_dashboard_tg, { stat = "p99", label = "p99" }],
          ]
        }
      },
      {
        type   = "metric"
        x      = 12
        y      = 11
        width  = 12
        height = 6
        properties = {
          title   = "Target health · blue"
          view    = "timeSeries"
          stacked = false
          region  = var.aws_region
          period  = 60
          yAxis   = { left = { min = 0 } }
          metrics = [
            ["AWS/ApplicationELB", "HealthyHostCount", "LoadBalancer", local.alb_dashboard_lb, "TargetGroup", local.alb_dashboard_tg, { stat = "Minimum", label = "Healthy" }],
            ["AWS/ApplicationELB", "UnHealthyHostCount", "LoadBalancer", local.alb_dashboard_lb, "TargetGroup", local.alb_dashboard_tg, { stat = "Maximum", label = "Unhealthy" }],
          ]
        }
      },

      # ---------------- Connections ----------------
      {
        type   = "metric"
        x      = 0
        y      = 17
        width  = 12
        height = 6
        properties = {
          title   = "Client connections · per minute"
          view    = "timeSeries"
          stacked = false
          region  = var.aws_region
          period  = 60
          yAxis   = { left = { min = 0 } }
          metrics = [
            ["AWS/ApplicationELB", "ActiveConnectionCount", "LoadBalancer", local.alb_dashboard_lb, { stat = "Sum", label = "Active" }],
            ["AWS/ApplicationELB", "NewConnectionCount", "LoadBalancer", local.alb_dashboard_lb, { stat = "Sum", label = "New" }],
            ["AWS/ApplicationELB", "RejectedConnectionCount", "LoadBalancer", local.alb_dashboard_lb, { stat = "Sum", label = "Rejected" }],
          ]
        }
      },
      {
        type   = "metric"
        x      = 12
        y      = 17
        width  = 12
        height = 6
        properties = {
          title   = "Connection / TLS errors"
          view    = "timeSeries"
          stacked = false
          region  = var.aws_region
          period  = 60
          yAxis   = { left = { min = 0 } }
          metrics = [
            ["AWS/ApplicationELB", "TargetConnectionErrorCount", "LoadBalancer", local.alb_dashboard_lb, "TargetGroup", local.alb_dashboard_tg, { stat = "Sum", label = "ALB → Nginx connect error" }],
            ["AWS/ApplicationELB", "TargetTLSNegotiationErrorCount", "LoadBalancer", local.alb_dashboard_lb, "TargetGroup", local.alb_dashboard_tg, { stat = "Sum", label = "ALB → Nginx TLS error" }],
            ["AWS/ApplicationELB", "ClientTLSNegotiationErrorCount", "LoadBalancer", local.alb_dashboard_lb, { stat = "Sum", label = "Client → ALB TLS error" }],
          ]
        }
      },
      {
        type   = "text"
        x      = 0
        y      = 23
        width  = 24
        height = 4
        properties = {
          markdown = "## Reading the signals\n- ALB 5xx는 ALB가 직접 만든 응답(타깃 없음·연결 실패 등)이고, Target 5xx는 Nginx/Backend가 응답한 오류입니다.\n- ALB 4xx는 인터넷 스캐너·봇 요청으로도 발생하므로 추세만 봅니다.\n- 응답시간은 트래픽이 적으면 요청 몇 건에 크게 흔들립니다. DNS 전환 전후 비교는 k6 결과와 함께 봅니다.\n- ALB → Nginx 구간은 HTTPS이므로 Nginx 인증서 문제는 TLS error로 나타납니다.\n- 지표가 없는 구간(요청 0건)은 그래프가 비어 보이는 것이 정상입니다."
        }
      },
    ]
  })
}

output "alb_dashboard_name" {
  description = "CloudWatch dashboard for ALB request rate, errors, and latency"
  value       = aws_cloudwatch_dashboard.alb.dashboard_name
}
