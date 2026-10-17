locals {
  migration_targets = merge(
    {
      v1-blue = split(":", data.terraform_remote_state.app.outputs.blue_target_group_arn)[5]
      backend = aws_lb_target_group.backend_green.arn_suffix
    },
    local.ai_market_enabled ? { market-http = aws_lb_target_group.market_http.arn_suffix } : {},
  )
  monitoring_lb = data.terraform_remote_state.app.outputs.alb_arn_suffix

  service_widgets = flatten([
    for index, name in sort(keys(local.scaling_services)) : [
      {
        type = "metric", x = index * 12, y = 5, width = 12, height = 6
        properties = {
          title = "${name} · CPU / Memory (%)", region = var.aws_region, period = 60, view = "timeSeries", stat = "Average"
          metrics = [
            ["AWS/ECS", "CPUUtilization", "ClusterName", aws_ecs_cluster.main.name, "ServiceName", local.scaling_services[name], { label = "CPU" }],
            ["AWS/ECS", "MemoryUtilization", "ClusterName", aws_ecs_cluster.main.name, "ServiceName", local.scaling_services[name], { label = "Memory" }],
          ]
          annotations = { horizontal = [{ value = 60, label = "Backend CPU scaling target", visible = name == "backend" }] }
        }
      },
      {
        type = "metric", x = index * 12, y = 11, width = 12, height = 6
        properties = {
          title = "${name} · Task counts", region = var.aws_region, period = 60, view = "timeSeries", stat = "Maximum"
          metrics = [for metric in ["DesiredTaskCount", "RunningTaskCount", "PendingTaskCount"] : [
            "ECS/ContainerInsights", metric, "ClusterName", aws_ecs_cluster.main.name, "ServiceName", local.scaling_services[name],
          ]]
        }
      },
    ]
  ])

  target_widgets = flatten([
    for index, name in sort(keys(local.migration_targets)) : [
      {
        type = "metric", x = index * 8, y = 29, width = 8, height = 6
        properties = {
          title = "${name} · requests / target errors", region = var.aws_region, period = 60, view = "timeSeries", stat = "Sum"
          metrics = [for metric in ["RequestCount", "HTTPCode_Target_4XX_Count", "HTTPCode_Target_5XX_Count", "TargetConnectionErrorCount"] : [
            "AWS/ApplicationELB", metric, "LoadBalancer", local.monitoring_lb, "TargetGroup", local.migration_targets[name],
          ]]
        }
      },
      {
        type = "metric", x = index * 8, y = 35, width = 8, height = 6
        properties = {
          title = "${name} · HTTP target latency (seconds)", region = var.aws_region, period = 60, view = "timeSeries"
          metrics = [for stat in ["p50", "p95", "p99"] : [
            "AWS/ApplicationELB", "TargetResponseTime", "LoadBalancer", local.monitoring_lb, "TargetGroup", local.migration_targets[name], { stat = stat, label = stat },
          ]]
        }
      },
      {
        type = "metric", x = index * 8, y = 41, width = 8, height = 6
        properties = {
          title = "${name} · healthy / unhealthy targets", region = var.aws_region, period = 60, view = "timeSeries"
          metrics = [
            ["AWS/ApplicationELB", "HealthyHostCount", "LoadBalancer", local.monitoring_lb, "TargetGroup", local.migration_targets[name], { stat = "Minimum", label = "Healthy (min)" }],
            ["AWS/ApplicationELB", "UnHealthyHostCount", "LoadBalancer", local.monitoring_lb, "TargetGroup", local.migration_targets[name], { stat = "Maximum", label = "Unhealthy (max)" }],
          ]
        }
      },
    ]
  ])

  client_widgets = flatten([
    for index, name in sort(keys(local.scaling_services)) : [
      {
        type = "metric", x = index * 12, y = 47, width = 12, height = 6
        properties = {
          title = "${name} · client requests / failures (upload required)", region = var.aws_region, period = 60, view = "timeSeries", stat = "Sum"
          metrics = [for metric in ["Requests", "Failures", "SSEReconnects"] : [
            { expression = "SEARCH('{StockSpoon/Experiments,ServiceName,Scenario} MetricName=\"${metric}\" ServiceName=\"${name}\"', 'Sum', 60)", id = "q${index}${lower(metric)}" },
          ]]
        }
      },
      {
        type = "metric", x = index * 12, y = 53, width = 12, height = 6
        properties = {
          title = "${name} · client HTTP / SSE latency p95 (ms)", region = var.aws_region, period = 60, view = "timeSeries"
          metrics = [for metric in ["RequestDurationMs", "SSEConnectDurationMs", "SSEEventGapMs"] : [
            { expression = "SEARCH('{StockSpoon/Experiments,ServiceName,Scenario} MetricName=\"${metric}\" ServiceName=\"${name}\"', 'p95', 60)", id = "q${index}${lower(metric)}" },
          ]]
        }
      },
    ]
  ])
}

resource "aws_cloudwatch_dashboard" "ecs_experiments" {
  dashboard_name = "${var.name_prefix}-ecs-experiments"
  dashboard_body = jsonencode({
    start          = "-PT3H"
    periodOverride = "inherit"
    widgets = concat([
      {
        type       = "text", x = 0, y = 0, width = 24, height = 2
        properties = { markdown = "# StockSpoon V2 · Scaling / Migration / Fault experiments\n서버·사용자 지표와 실험 시각을 함께 확인합니다. 장중 최소 3 / 그 외 최소 2 / 최대 4. ALB 지연은 SSE 이벤트 수신 지연을 나타내지 않습니다. 클라이언트 지표는 업로드 후 표시되며 여러 실험을 동시에 실행하지 않습니다. 알람 알림 수신자는 별도 설정이 필요합니다." }
      },
      {
        type = "alarm", x = 0, y = 2, width = 24, height = 3
        properties = {
          title = "Service health alarms (separate from scaling alarms)"
          alarms = concat(
            [for alarm in aws_cloudwatch_metric_alarm.no_healthy_targets : "arn:${local.partition}:cloudwatch:${var.aws_region}:${local.account_id}:alarm:${alarm.alarm_name}"],
            [for alarm in aws_cloudwatch_metric_alarm.target_errors : "arn:${local.partition}:cloudwatch:${var.aws_region}:${local.account_id}:alarm:${alarm.alarm_name}"],
          )
        }
      },
      {
        type = "metric", x = 0, y = 17, width = 12, height = 6
        properties = {
          title       = "SSE · average active connections per Task", region = var.aws_region, period = 60, stat = "Average", view = "timeSeries"
          metrics     = local.ai_market_enabled ? [["StockSpoon/ECS", "ActiveSSEConnections", "ClusterName", aws_ecs_cluster.main.name, "ServiceName", local.scaling_services["market-http"]]] : []
          annotations = { horizontal = [{ value = 400, label = "Scaling target" }] }
        }
      },
      {
        type = "metric", x = 12, y = 17, width = 12, height = 6
        properties = {
          title   = "Shared ASG · instance counts", region = var.aws_region, period = 60, stat = "Maximum", view = "timeSeries"
          metrics = [for metric in ["GroupDesiredCapacity", "GroupInServiceInstances", "GroupPendingInstances", "GroupTerminatingInstances", "GroupMinSize", "GroupMaxSize"] : ["AWS/AutoScaling", metric, "AutoScalingGroupName", aws_autoscaling_group.service.name]]
        }
      },
      {
        type = "metric", x = 0, y = 23, width = 12, height = 6
        properties = {
          title       = "Capacity provider · reservation (%)", region = var.aws_region, period = 60, stat = "Average", view = "timeSeries"
          metrics     = [["AWS/ECS/ManagedScaling", "CapacityProviderReservation", "CapacityProviderName", aws_ecs_capacity_provider.service.name, "ClusterName", aws_ecs_cluster.main.name]]
          annotations = { horizontal = [{ value = var.service_target_capacity, label = "Capacity target" }] }
        }
      },
      {
        type = "metric", x = 12, y = 23, width = 12, height = 6
        properties = {
          title   = "Shared ALB · load balancer errors / rejected connections", region = var.aws_region, period = 60, stat = "Sum", view = "timeSeries"
          metrics = [for metric in ["HTTPCode_ELB_5XX_Count", "RejectedConnectionCount", "ClientTLSNegotiationErrorCount"] : ["AWS/ApplicationELB", metric, "LoadBalancer", local.monitoring_lb]]
        }
      },
      {
        type = "log", x = 0, y = 59, width = 24, height = 6
        properties = {
          title = "ECS / ASG lifecycle timeline", region = var.aws_region, view = "table"
          query = "SOURCE '${aws_cloudwatch_log_group.lifecycle.name}' | fields @timestamp, source, `detail-type`, detail.eventName, detail.lastStatus, detail.stoppedReason, detail.reason, @message | sort @timestamp desc | limit 100"
        }
      },
      {
        type = "log", x = 0, y = 65, width = 24, height = 6
        properties = {
          title = "Experiment markers / client results", region = var.aws_region, view = "table"
          query = "SOURCE '${aws_cloudwatch_log_group.experiments.name}' | fields @timestamp, TestId, ServiceName, Scenario, Event, Message, @message | sort @timestamp desc | limit 100"
        }
      },
      {
        type = "log", x = 0, y = 71, width = 24, height = 6
        properties = {
          title = "Backend / SSE application logs", region = var.aws_region, view = "table"
          query = "SOURCE '${aws_cloudwatch_log_group.backend.name}' | SOURCE '${aws_cloudwatch_log_group.market_http.name}' | fields @timestamp, @log, @logStream, @message | sort @timestamp desc | limit 100"
        }
      },
    ], local.service_widgets, local.target_widgets, local.client_widgets)
  })
}

output "ecs_experiments_dashboard_url" {
  description = "CloudWatch dashboard for V2 scaling, migration, and fault experiments"
  value       = "https://${var.aws_region}.console.aws.amazon.com/cloudwatch/home?region=${var.aws_region}#dashboards/dashboard/${aws_cloudwatch_dashboard.ecs_experiments.dashboard_name}"
}

output "ecs_experiment_log_group_name" {
  value = aws_cloudwatch_log_group.experiments.name
}

output "ecs_fault_stop_alarm_arns" {
  description = "Health alarms available for a future FIS experiment; no experiment is created here"
  value = merge(
    { for name, alarm in aws_cloudwatch_metric_alarm.no_healthy_targets : "${name}-availability" => alarm.arn },
    { for name, alarm in aws_cloudwatch_metric_alarm.target_errors : "${name}-errors" => alarm.arn },
  )
}
