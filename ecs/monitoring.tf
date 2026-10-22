# ECS -> monitoring -> shared-infra. Monitoring never depends on ECS state.
variable "plg_tempo_enabled" {
  description = "Connect ECS to an already-applied monitoring root and create its Alloy daemon"
  type        = bool
  default     = true
}

variable "telemetry_trace_sample_ratio" {
  description = "Fraction of new root traces to sample; use 1 temporarily for a controlled diagnostic test"
  type        = number
  default     = 0.1

  validation {
    condition     = var.telemetry_trace_sample_ratio >= 0 && var.telemetry_trace_sample_ratio <= 1
    error_message = "telemetry_trace_sample_ratio must be between 0 and 1."
  }
}

locals {
  telemetry_name   = "${var.name_prefix}-telemetry"
  telemetry_server = var.plg_tempo_enabled ? data.terraform_remote_state.monitoring[0].outputs.plg_tempo : null
  # Export traces only: this endpoint is Tempo, not an OTLP metrics/logs backend.
  telemetry_otlp_environment = var.plg_tempo_enabled ? [
    { name = "OTEL_EXPORTER_OTLP_ENDPOINT", value = local.telemetry_server.otlp_http_endpoint },
    { name = "OTEL_EXPORTER_OTLP_PROTOCOL", value = "http/protobuf" },
    { name = "OTEL_RESOURCE_ATTRIBUTES", value = "deployment.environment.name=prod" },
    { name = "OTEL_TRACES_EXPORTER", value = "otlp" },
    { name = "OTEL_TRACES_SAMPLER", value = "parentbased_traceidratio" },
    { name = "OTEL_TRACES_SAMPLER_ARG", value = tostring(var.telemetry_trace_sample_ratio) },
    { name = "OTEL_METRICS_EXPORTER", value = "none" },
    { name = "OTEL_LOGS_EXPORTER", value = "none" },
  ] : []
  telemetry_trace_sources = var.plg_tempo_enabled ? merge({
    backend     = aws_security_group.backend_task.id
    market_http = aws_security_group.market_http_task.id
    }, var.frontend_enabled ? {
    frontend = aws_security_group.frontend_task[0].id
    } : {}, var.backend_collector_enabled ? {
    backend_collector = aws_security_group.backend_collector[0].id
  } : {}) : {}
}

data "terraform_remote_state" "monitoring" {
  count   = var.plg_tempo_enabled ? 1 : 0
  backend = "s3"
  config = {
    bucket = "stockspoon-terraform-state-v2"
    key    = "monitoring/terraform.tfstate"
    region = "ap-northeast-2"
  }
  lifecycle {
    postcondition {
      condition     = try(self.outputs.plg_tempo.security_group_id != null, false)
      error_message = "Apply monitoring with plg_tempo_enabled=true before enabling ECS telemetry."
    }
  }
}

resource "aws_vpc_security_group_ingress_rule" "telemetry_from_alloy" {
  for_each = var.plg_tempo_enabled ? {
    loki       = 3100
    prometheus = 9090
  } : {}
  security_group_id            = local.telemetry_server.security_group_id
  referenced_security_group_id = aws_security_group.ecs_instance.id
  from_port                    = each.value
  to_port                      = each.value
  ip_protocol                  = "tcp"
  description                  = "ECS host Alloy to V2 ${each.key}"
}

resource "aws_vpc_security_group_ingress_rule" "telemetry_traces" {
  for_each                     = local.telemetry_trace_sources
  security_group_id            = local.telemetry_server.security_group_id
  referenced_security_group_id = each.value
  from_port                    = 4318
  to_port                      = 4318
  ip_protocol                  = "tcp"
  description                  = "${each.key} OTLP HTTP traces to V2 Tempo"
}

resource "aws_vpc_security_group_egress_rule" "frontend_to_telemetry" {
  count                        = var.plg_tempo_enabled && var.frontend_enabled ? 1 : 0
  security_group_id            = aws_security_group.frontend_task[0].id
  referenced_security_group_id = local.telemetry_server.security_group_id
  from_port                    = 4318
  to_port                      = 4318
  ip_protocol                  = "tcp"
  description                  = "Frontend server OTLP HTTP traces to V2 Tempo"
}

resource "aws_cloudwatch_log_group" "telemetry_alloy" {
  count             = var.plg_tempo_enabled ? 1 : 0
  name              = "/ecs/${local.telemetry_name}/alloy"
  retention_in_days = 7
}

resource "aws_ecs_task_definition" "telemetry_alloy" {
  count                    = var.plg_tempo_enabled ? 1 : 0
  family                   = "${local.telemetry_name}-alloy"
  requires_compatibilities = ["EC2"]
  network_mode             = "host"
  pid_mode                 = "host"
  execution_role_arn       = aws_iam_role.ecs_task_execution.arn

  volume {
    name      = "docker-socket"
    host_path = "/var/run/docker.sock"
  }
  volume {
    name      = "host-root"
    host_path = "/"
  }
  volume {
    name      = "alloy-data"
    host_path = "/var/lib/stockspoon-v2-alloy"
  }

  container_definitions = jsonencode([{
    name              = "v2-alloy"
    image             = "grafana/alloy:v1.20.1"
    essential         = true
    cpu               = 128
    memoryReservation = 256
    memory            = 512
    user              = "0:0"
    entryPoint        = ["/bin/sh", "-ec"]
    command = [join(" ", [
      "printf '%s' \"$ALLOY_CONFIG\" > /tmp/config.alloy;",
      "exec /bin/alloy run --server.http.listen-addr=127.0.0.1:12345",
      "--storage.path=/var/lib/alloy /tmp/config.alloy"
    ])]
    environment = [
      { name = "ALLOY_CONFIG", value = file("${path.module}/alloy/config.alloy") },
      { name = "ECS_CLUSTER", value = aws_ecs_cluster.main.name },
      { name = "DEPLOYMENT_ENVIRONMENT", value = "prod" },
      { name = "TASK_FAMILY_REGEX", value = "${var.name_prefix}-(backend|backend-collector|market-http|frontend)" },
      { name = "LOKI_PUSH_URL", value = local.telemetry_server.loki_push_url },
      { name = "PROMETHEUS_WRITE_URL", value = local.telemetry_server.prometheus_write_url },
    ]
    mountPoints = [
      { sourceVolume = "docker-socket", containerPath = "/var/run/docker.sock", readOnly = true },
      { sourceVolume = "host-root", containerPath = "/host", readOnly = true },
      { sourceVolume = "alloy-data", containerPath = "/var/lib/alloy", readOnly = false },
    ]
    logConfiguration = {
      logDriver = "awslogs"
      options = {
        awslogs-group         = aws_cloudwatch_log_group.telemetry_alloy[0].name
        awslogs-region        = var.aws_region
        awslogs-stream-prefix = "alloy"
        mode                  = "non-blocking"
        max-buffer-size       = "4m"
      }
    }
  }])
}

resource "aws_ecs_service" "telemetry_alloy" {
  count               = var.plg_tempo_enabled ? 1 : 0
  name                = "${local.telemetry_name}-alloy"
  cluster             = aws_ecs_cluster.main.id
  task_definition     = aws_ecs_task_definition.telemetry_alloy[0].arn
  scheduling_strategy = "DAEMON"
  launch_type         = "EC2"

  # Fixed host paths allow one writer per host; old daemon stops before replacement.
  deployment_minimum_healthy_percent = 0
  deployment_maximum_percent         = 100

  depends_on = [
    aws_vpc_security_group_ingress_rule.telemetry_from_alloy,
  ]
}
