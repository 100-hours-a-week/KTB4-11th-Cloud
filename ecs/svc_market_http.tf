# market-http (Socket 역할): 현재가 REST·SSE와 과거 시세를 제공하는 공개 HTTP 서버
# 외부 경로 /market/* 를 ALB가 접두사를 제거해 전달한다. (cross_root_rules.tf)

# ---------------------------------------------------------------------------
# Logs
# ---------------------------------------------------------------------------

resource "aws_cloudwatch_log_group" "market_http" {
  name              = "/ecs/${var.name_prefix}/market-http"
  retention_in_days = var.container_log_retention_days
}

# ---------------------------------------------------------------------------
# Task Role: Valkey IAM 인증 (socket 사용자)
# ---------------------------------------------------------------------------

resource "aws_iam_role" "market_http_task" {
  name               = "${var.name_prefix}-market-http-task-role"
  description        = "Role assumed by the market-http containers"
  assume_role_policy = data.aws_iam_policy_document.ecs_tasks_assume_role.json
}

resource "aws_iam_role_policy_attachment" "market_http_valkey" {
  role       = aws_iam_role.market_http_task.name
  policy_arn = local.valkey_policies[local.market_http_valkey_role]
}

# ---------------------------------------------------------------------------
# Security Group
# ---------------------------------------------------------------------------

resource "aws_security_group" "market_http_task" {
  name        = "${var.name_prefix}-market-http-task-sg"
  description = "market-http ECS tasks (inbound only from the ALB)"
  vpc_id      = data.terraform_remote_state.shared.outputs.vpc_id

  tags = {
    Name = "${var.name_prefix}-market-http-task-sg"
  }
}

resource "aws_vpc_security_group_ingress_rule" "market_http_task_from_alb" {
  security_group_id            = aws_security_group.market_http_task.id
  referenced_security_group_id = data.terraform_remote_state.app.outputs.alb_security_group_id
  from_port                    = var.market_http_container_port
  to_port                      = var.market_http_container_port
  ip_protocol                  = "tcp"
  description                  = "Allow application traffic and health checks from the ALB"
}

# Valkey, V1 AI QuestDB
resource "aws_vpc_security_group_egress_rule" "market_http_task_all" {
  security_group_id = aws_security_group.market_http_task.id
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "-1"
  description       = "Allow outbound to dependencies"
}

# ---------------------------------------------------------------------------
# Target Group
# ---------------------------------------------------------------------------

resource "aws_lb_target_group" "market_http" {
  name                 = "${var.name_prefix}-market-http"
  port                 = var.market_http_container_port
  protocol             = "HTTP"
  target_type          = "ip"
  vpc_id               = data.terraform_remote_state.shared.outputs.vpc_id
  deregistration_delay = var.market_http_deregistration_delay_seconds

  health_check {
    enabled             = true
    protocol            = "HTTP"
    path                = "/health"
    matcher             = "200"
    interval            = 10
    timeout             = 5
    healthy_threshold   = 2
    unhealthy_threshold = 2
  }

  tags = {
    Name = "${var.name_prefix}-market-http"
  }
}

# ---------------------------------------------------------------------------
# Task Definition
# ---------------------------------------------------------------------------

resource "aws_ecs_task_definition" "market_http" {
  count = local.ai_market_enabled ? 1 : 0

  skip_destroy = true

  lifecycle {
    ignore_changes = [
      family, network_mode, requires_compatibilities, cpu, memory,
      execution_role_arn, task_role_arn, runtime_platform, container_definitions,
    ]
  }

  family                   = "${var.name_prefix}-market-http"
  network_mode             = "awsvpc"
  requires_compatibilities = ["EC2"]
  cpu                      = var.market_http_task_cpu
  memory                   = var.market_http_task_memory
  execution_role_arn       = aws_iam_role.ecs_task_execution.arn
  task_role_arn            = aws_iam_role.market_http_task.arn

  runtime_platform {
    operating_system_family = "LINUX"
    cpu_architecture        = "X86_64"
  }

  container_definitions = jsonencode([
    {
      name        = "market-http"
      image       = local.ai_image
      command     = ["market-http"]
      essential   = true
      stopTimeout = var.market_http_stop_timeout_seconds

      healthCheck = {
        command = [
          "CMD-SHELL",
          "python -c \"import urllib.request; urllib.request.urlopen('http://127.0.0.1:${var.market_http_container_port}/health', timeout=3)\" || exit 1",
        ]
        interval    = 30
        timeout     = 5
        retries     = 3
        startPeriod = 30
      }

      portMappings = [
        {
          containerPort = var.market_http_container_port
          protocol      = "tcp"
        }
      ]

      # 비밀값이 없으므로 모두 environment로 주입한다. (QuestDB는 SG로만 접근 통제, 인증 도입 시 secrets로 이동)
      environment = [
        { name = "MARKET_HTTP_HOST", value = "0.0.0.0" },
        { name = "MARKET_HTTP_PORT", value = tostring(var.market_http_container_port) },
        { name = "MARKET_HTTP_QUESTDB_CONF", value = "ws::addr=${local.ai_private_ip}:${var.ai_questdb_http_port};" },
        { name = "MARKET_HTTP_VALKEY_HOST", value = local.valkey_endpoint },
        { name = "MARKET_HTTP_VALKEY_PORT", value = tostring(local.valkey_port) },
        { name = "MARKET_HTTP_VALKEY_USERNAME", value = local.valkey_users[local.market_http_valkey_role] },
        { name = "MARKET_HTTP_VALKEY_CACHE_NAME", value = local.valkey_cache_name },
        { name = "MARKET_HTTP_VALKEY_TLS", value = "true" },
        { name = "MARKET_HTTP_VALKEY_AUTH_MODE", value = "iam" },
        { name = "MARKET_HTTP_AWS_REGION", value = var.aws_region },
        { name = "MARKET_HTTP_CORS_ORIGINS", value = jsonencode(["*"]) },
        { name = "MARKET_HTTP_CORS_HEADERS", value = jsonencode(["*"]) },
        { name = "MARKET_HTTP_DOCS_ENABLED", value = "true" },
        { name = "MARKET_HTTP_DOCS_PATH_PREFIX", value = "/market" },
        { name = "MARKET_HTTP_LOG_LEVEL", value = var.market_http_log_level },
        { name = "MARKET_HTTP_METRICS_NAMESPACE", value = local.sse_metrics_namespace },
        { name = "MARKET_HTTP_METRICS_CLUSTER_NAME", value = aws_ecs_cluster.main.name },
        { name = "MARKET_HTTP_METRICS_SERVICE_NAME", value = "${var.name_prefix}-market-http" },
      ]

      logConfiguration = {
        logDriver = "awslogs"
        options = {
          awslogs-group         = aws_cloudwatch_log_group.market_http.name
          awslogs-region        = var.aws_region
          awslogs-stream-prefix = "market-http"
        }
      }
    }
  ])
}

# ---------------------------------------------------------------------------
# ECS Service
# ---------------------------------------------------------------------------

resource "aws_ecs_service" "market_http" {
  count = local.ai_market_enabled ? 1 : 0

  name            = "${var.name_prefix}-market-http"
  cluster         = aws_ecs_cluster.main.id
  task_definition = aws_ecs_task_definition.market_http[0].arn
  desired_count   = var.market_http_desired_count

  capacity_provider_strategy {
    capacity_provider = aws_ecs_capacity_provider.service.name
    weight            = 1
  }

  network_configuration {
    subnets          = data.terraform_remote_state.shared.outputs.private_subnet_ids
    security_groups  = [aws_security_group.market_http_task.id]
    assign_public_ip = false
  }

  load_balancer {
    target_group_arn = aws_lb_target_group.market_http.arn
    container_name   = "market-http"
    container_port   = var.market_http_container_port
  }

  health_check_grace_period_seconds  = var.market_http_health_check_grace_period_seconds
  deployment_minimum_healthy_percent = 100
  deployment_maximum_percent         = 200

  deployment_circuit_breaker {
    enable   = true
    rollback = true
  }

  ordered_placement_strategy {
    type  = "spread"
    field = "attribute:ecs.availability-zone"
  }

  ordered_placement_strategy {
    type  = "spread"
    field = "instanceId"
  }

  propagate_tags          = "SERVICE"
  enable_ecs_managed_tags = true

  lifecycle {
    ignore_changes = [task_definition]
  }

  depends_on = [
    aws_lb_listener_rule.market_http,
    aws_ecs_cluster_capacity_providers.main,
    aws_iam_role_policy_attachment.market_http_valkey,
  ]
}
