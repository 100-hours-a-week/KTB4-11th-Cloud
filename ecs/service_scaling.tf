locals {
  sse_metrics_namespace = "StockSpoon/ECS"
  scaling_services = merge(
    { backend = aws_ecs_service.backend.name },
    local.ai_market_enabled ? { market-http = aws_ecs_service.market_http[0].name } : {},
  )
}

resource "aws_appautoscaling_target" "service" {
  for_each = { backend = local.scaling_services.backend }

  service_namespace  = "ecs"
  resource_id        = "service/${aws_ecs_cluster.main.name}/${each.value}"
  scalable_dimension = "ecs:service:DesiredCount"
  min_capacity       = 2
  max_capacity       = 4

  # 예약 확장이 바꾼 최소치를 일반 apply가 개장 중에 되돌리지 않는다.
  lifecycle {
    ignore_changes = [min_capacity]
  }
}

# 부하 테스트 때 분리한 리소스 주소를 유지해 확장 대상의 삭제/재생성을 방지한다.
moved {
  from = aws_appautoscaling_target.service["market-http"]
  to   = aws_appautoscaling_target.market_http[0]
}

resource "aws_appautoscaling_target" "market_http" {
  count = local.ai_market_enabled ? 1 : 0

  # 단일 Task 검증 이후의 운영 범위: 평상시 2개, 자동 확장 최대 3개.
  service_namespace  = "ecs"
  resource_id        = "service/${aws_ecs_cluster.main.name}/${aws_ecs_service.market_http[0].name}"
  scalable_dimension = "ecs:service:DesiredCount"
  min_capacity       = 2
  max_capacity       = 3
}

locals {
  service_scaling_targets = merge(
    { backend = aws_appautoscaling_target.service["backend"] },
    local.ai_market_enabled ? { market-http = aws_appautoscaling_target.market_http[0] } : {},
  )
}

resource "aws_appautoscaling_policy" "backend_cpu" {
  name               = "${var.name_prefix}-backend-cpu"
  policy_type        = "TargetTrackingScaling"
  service_namespace  = aws_appautoscaling_target.service["backend"].service_namespace
  resource_id        = aws_appautoscaling_target.service["backend"].resource_id
  scalable_dimension = aws_appautoscaling_target.service["backend"].scalable_dimension

  target_tracking_scaling_policy_configuration {
    target_value       = 60
    scale_out_cooldown = 60
    scale_in_cooldown  = 300

    predefined_metric_specification {
      predefined_metric_type = "ECSServiceAverageCPUUtilization"
    }
  }
}

resource "aws_appautoscaling_policy" "market_http_connections" {
  count = local.ai_market_enabled ? 1 : 0

  name               = "${var.name_prefix}-market-http-sse-connections"
  policy_type        = "TargetTrackingScaling"
  service_namespace  = aws_appautoscaling_target.market_http[0].service_namespace
  resource_id        = aws_appautoscaling_target.market_http[0].resource_id
  scalable_dimension = aws_appautoscaling_target.market_http[0].scalable_dimension

  target_tracking_scaling_policy_configuration {
    # 서비스에 속한 Task별 연결 수 표본의 평균. Task별 강제 접속 상한은 아니다.
    target_value       = 1000
    scale_out_cooldown = 60
    scale_in_cooldown  = 300

    customized_metric_specification {
      namespace   = local.sse_metrics_namespace
      metric_name = "ActiveSSEConnections"
      statistic   = "Average"
      unit        = "Count"

      dimensions {
        name  = "ClusterName"
        value = aws_ecs_cluster.main.name
      }

      dimensions {
        name  = "ServiceName"
        value = aws_ecs_service.market_http[0].name
      }
    }
  }
}

# 설정된 서비스의 선확장과 최소치 복귀를 한 쌍으로 관리한다.
resource "aws_appautoscaling_scheduled_action" "preopen" {
  for_each = {
    for service, config in var.service_preopen_scaling : service => config
    if contains(keys(local.scaling_services), service)
  }

  name               = "${var.name_prefix}-${each.key}-preopen"
  service_namespace  = local.service_scaling_targets[each.key].service_namespace
  resource_id        = local.service_scaling_targets[each.key].resource_id
  scalable_dimension = local.service_scaling_targets[each.key].scalable_dimension
  schedule           = each.value.preopen_schedule
  timezone           = "Asia/Seoul"

  scalable_target_action {
    min_capacity = each.value.min_capacity
    max_capacity = local.service_scaling_targets[each.key].max_capacity
  }
}

resource "aws_appautoscaling_scheduled_action" "restore" {
  for_each = aws_appautoscaling_scheduled_action.preopen

  name               = "${var.name_prefix}-${each.key}-restore-minimum"
  service_namespace  = each.value.service_namespace
  resource_id        = each.value.resource_id
  scalable_dimension = each.value.scalable_dimension
  schedule           = var.service_preopen_scaling[each.key].restore_schedule
  timezone           = "Asia/Seoul"

  scalable_target_action {
    min_capacity = 2
    max_capacity = local.service_scaling_targets[each.key].max_capacity
  }
}
