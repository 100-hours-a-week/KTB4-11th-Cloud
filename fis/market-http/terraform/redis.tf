# Templates only: no experiment starts and no ECS service rollout is performed.
# Network actions additionally require a fault-enabled Task and an Online SSM sidecar.
locals {
  redis_endpoint = "stockspoon-v2-prod-valkey-kmikux.serverless.apn2.cache.amazonaws.com"
  redis_scenarios = {
    R1 = { action = "aws:ecs:task-network-packet-loss", workload = "900 SSE; 2 Tasks" }
    R2 = { action = "aws:ecs:task-network-latency", workload = "900 SSE; 2 Tasks" }
    R3 = { action = "aws:ecs:task-network-packet-loss", workload = "2000 SSE; 3 Tasks" }
  }
  # Egress only: validate actual Pub/Sub interruption and recovery separately.
  # Endpoint IPs are selected, without a port restriction.
  redis_parameters = {
    R1 = { duration = "PT1M", sources = local.redis_endpoint, lossPercent = "100", flowsPercent = "100", useEcsFaultInjectionEndpoints = "true", installDependencies = "false" }
    R2 = { duration = "PT1M", sources = local.redis_endpoint, delayMilliseconds = "200", jitterMilliseconds = "10", flowsPercent = "100", useEcsFaultInjectionEndpoints = "true", installDependencies = "false" }
    R3 = { duration = "PT1M", sources = local.redis_endpoint, lossPercent = "100", flowsPercent = "100", useEcsFaultInjectionEndpoints = "true", installDependencies = "false" }
  }
}

resource "aws_iam_role" "redis_fis" {
  name               = "stockspoon-market-http-fis-redis"
  assume_role_policy = aws_iam_role.fis.assume_role_policy
}

resource "aws_iam_role_policy" "redis_fis" {
  role = aws_iam_role.redis_fis.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      { Effect = "Allow", Action = ["ecs:DescribeTasks"], Resource = var.target_task_arn },
      {
        Effect = "Allow", Action = ["ssm:SendCommand"]
        Resource = [
          "arn:aws:ssm:ap-northeast-2::document/AWSFIS-Run-Network-Packet-Loss-ECS",
          "arn:aws:ssm:ap-northeast-2::document/AWSFIS-Run-Network-Latency-ECS"
        ]
      },
      {
        Effect   = "Allow", Action = ["ssm:SendCommand"]
        Resource = "arn:aws:ssm:ap-northeast-2:250832562715:managed-instance/*"
        Condition = { StringEquals = {
          "ssm:resourceTag/ECS_TASK_ARN"            = var.target_task_arn
          "ssm:resourceTag/FAULT_INJECTION_SIDECAR" = "true"
        } }
      },
      # These control-plane/list/log-delivery operations require wildcard scope.
      {
        Effect = "Allow", Resource = "*"
        Action = ["ecs:DescribeContainerInstances", "ec2:DescribeInstances", "ec2:DescribeSubnets", "ssm:ListCommands", "ssm:CancelCommand", "tag:GetResources", "cloudwatch:DescribeAlarms",
        "logs:CreateLogDelivery", "logs:PutResourcePolicy", "logs:DescribeResourcePolicies", "logs:DescribeLogGroups"]
      }
    ]
  })
}

resource "aws_cloudwatch_log_group" "redis_fis" {
  name              = "/aws/vendedlogs/fis/stockspoon-market-http-redis"
  retention_in_days = 30
}

resource "aws_fis_experiment_template" "redis" {
  for_each    = local.redis_scenarios
  description = "${each.key} market-http Redis fault; ${each.value.workload}; requires network readiness; manual start only"
  role_arn    = aws_iam_role.redis_fis.arn

  log_configuration {
    log_schema_version = 2
    cloudwatch_logs_configuration {
      log_group_arn = "${aws_cloudwatch_log_group.redis_fis.arn}:*"
    }
  }
  experiment_options {
    account_targeting            = "single-account"
    empty_target_resolution_mode = "fail"
  }
  dynamic "stop_condition" {
    for_each = var.stop_alarm_arns
    content {
      source = "aws:cloudwatch:alarm"
      value  = stop_condition.value
    }
  }
  target {
    name           = "VerifiedMarketHttpTask"
    resource_type  = "aws:ecs:task"
    resource_arns  = [var.target_task_arn]
    selection_mode = "COUNT(1)"
  }
  action {
    name      = "RedisNetworkFault"
    action_id = each.value.action
    target {
      key   = "Tasks"
      value = "VerifiedMarketHttpTask"
    }
    dynamic "parameter" {
      for_each = local.redis_parameters[each.key]
      content {
        key   = parameter.key
        value = parameter.value
      }
    }
  }
  action {
    name        = "ObserveRecovery"
    action_id   = "aws:fis:wait"
    start_after = ["RedisNetworkFault"]
    parameter {
      key   = "duration"
      value = "PT10M"
    }
  }
  tags       = { Name = "stockspoon-market-http-fis-${lower(each.key)}", Scenario = each.key }
  depends_on = [aws_iam_role_policy.redis_fis]
}

output "redis_template_ids" {
  value = { for scenario, template in aws_fis_experiment_template.redis : scenario => template.id }
}
output "redis_log_group_name" {
  value = aws_cloudwatch_log_group.redis_fis.name
}
