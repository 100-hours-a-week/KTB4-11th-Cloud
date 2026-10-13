# market-streamer (Market Data 역할): 키움 0B WebSocket 한 세션으로 KOSPI 200 체결가를 받아 Valkey에 기록
#
# - 같은 키움 키로 세션이 겹치지 않도록 Task는 항상 1개다. (Active/Standby 역할 결정 구현 전)
# - 앱은 STOP_AT(KST)에 exit 0 하는 배치 구조이고, 그 이후에 시작하면 바로 종료한다.
#   기본값 15:40 그대로 ECS Service에서 돌리면 장 마감 후부터 자정까지 ECS가 재시작을 반복한다.
#   코드 변경 없이 STOP_AT을 23:59로 두어 하루 1번(23:59) 재시작하는 상주 서비스처럼 운영한다.
#   23:59~24:00 사이 재시작은 Postgres 조회·Valkey ping 후 즉시 종료되며 키움에는 접속하지 않는다.
#   장외 시간에는 키움 세션만 유지되고 수신 데이터는 없다.
# - 인바운드가 없으므로 Load Balancer를 연결하지 않는다.
# - Worker ASG가 생기기 전까지 Service ASG에서 실행한다. (Match Engine 도입 시 이전)

# ---------------------------------------------------------------------------
# Logs
# ---------------------------------------------------------------------------

resource "aws_cloudwatch_log_group" "market_streamer" {
  name              = "/ecs/${var.name_prefix}/market-streamer"
  retention_in_days = var.container_log_retention_days
}

# ---------------------------------------------------------------------------
# Task Role: Valkey IAM 인증 (market-data 사용자)
# ---------------------------------------------------------------------------

resource "aws_iam_role" "market_streamer_task" {
  name               = "${var.name_prefix}-market-streamer-task-role"
  description        = "Role assumed by the market-streamer container"
  assume_role_policy = data.aws_iam_policy_document.ecs_tasks_assume_role.json
}

resource "aws_iam_role_policy_attachment" "market_streamer_valkey" {
  role       = aws_iam_role.market_streamer_task.name
  policy_arn = local.valkey_policies[local.market_streamer_valkey_role]
}

# ---------------------------------------------------------------------------
# Security Group (인바운드 없음)
# ---------------------------------------------------------------------------

resource "aws_security_group" "market_streamer_task" {
  name        = "${var.name_prefix}-market-streamer-task-sg"
  description = "market-streamer ECS task (no inbound)"
  vpc_id      = data.terraform_remote_state.shared.outputs.vpc_id

  tags = {
    Name = "${var.name_prefix}-market-streamer-task-sg"
  }
}

# 키움 API(NAT 경유), Valkey, V1 AI PostgreSQL
resource "aws_vpc_security_group_egress_rule" "market_streamer_task_all" {
  security_group_id = aws_security_group.market_streamer_task.id
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "-1"
  description       = "Allow outbound to Kiwoom and dependencies"
}

# ---------------------------------------------------------------------------
# Task Definition
# ---------------------------------------------------------------------------

resource "aws_ecs_task_definition" "market_streamer" {
  count = local.ai_market_enabled ? 1 : 0

  family                   = "${var.name_prefix}-market-streamer"
  network_mode             = "awsvpc"
  requires_compatibilities = ["EC2"]
  cpu                      = var.market_streamer_task_cpu
  memory                   = var.market_streamer_task_memory
  execution_role_arn       = aws_iam_role.ecs_task_execution.arn
  task_role_arn            = aws_iam_role.market_streamer_task.arn

  runtime_platform {
    operating_system_family = "LINUX"
    cpu_architecture        = "X86_64"
  }

  container_definitions = jsonencode([
    {
      name        = "market-streamer"
      image       = local.ai_image
      command     = ["market-streamer"]
      essential   = true
      stopTimeout = var.market_streamer_stop_timeout_seconds

      environment = [
        { name = "MARKET_STREAMER_STOP_AT", value = var.market_streamer_stop_at },
        { name = "MARKET_STREAMER_KIWOOM_MODE", value = "real" },
        { name = "MARKET_STREAMER_INDEX_NAME", value = "KOSPI200" },
        { name = "MARKET_STREAMER_VALKEY_HOST", value = local.valkey_endpoint },
        { name = "MARKET_STREAMER_VALKEY_PORT", value = tostring(local.valkey_port) },
        { name = "MARKET_STREAMER_VALKEY_USERNAME", value = local.valkey_users[local.market_streamer_valkey_role] },
        { name = "MARKET_STREAMER_VALKEY_CACHE_NAME", value = local.valkey_cache_name },
        { name = "MARKET_STREAMER_VALKEY_TLS", value = "true" },
        { name = "MARKET_STREAMER_VALKEY_AUTH_MODE", value = "iam" },
        { name = "MARKET_STREAMER_AWS_REGION", value = var.aws_region },
        { name = "MARKET_STREAMER_LOG_LEVEL", value = var.market_streamer_log_level },
      ]

      # SSM SecureString (콘솔·CLI로 직접 등록, README 참고)
      # POSTGRES_DSN 예: postgresql+psycopg://<user>:<password>@<V1 AI private IP>:5432/<db>
      secrets = [
        for name in ["POSTGRES_DSN", "KIWOOM_APP_KEY", "KIWOOM_SECRET_KEY"] : {
          name      = "MARKET_STREAMER_${name}"
          valueFrom = "arn:${local.partition}:ssm:${var.aws_region}:${local.account_id}:parameter${var.ssm_parameter_path_prefix}/market-streamer/${name}"
        }
      ]

      logConfiguration = {
        logDriver = "awslogs"
        options = {
          awslogs-group         = aws_cloudwatch_log_group.market_streamer.name
          awslogs-region        = var.aws_region
          awslogs-stream-prefix = "market-streamer"
        }
      }
    }
  ])
}

# ---------------------------------------------------------------------------
# ECS Service (Task 1개 고정, Auto Scaling 없음)
# ---------------------------------------------------------------------------

resource "aws_ecs_service" "market_streamer" {
  count = local.ai_market_enabled ? 1 : 0

  name            = "${var.name_prefix}-market-streamer"
  cluster         = aws_ecs_cluster.main.id
  task_definition = aws_ecs_task_definition.market_streamer[0].arn
  desired_count   = 1

  capacity_provider_strategy {
    capacity_provider = aws_ecs_capacity_provider.service.name
    weight            = 1
  }

  network_configuration {
    subnets          = data.terraform_remote_state.shared.outputs.private_subnet_ids
    security_groups  = [aws_security_group.market_streamer_task.id]
    assign_public_ip = false
  }

  # 기존 Task를 먼저 내린 뒤 새 Task를 띄워 키움 세션이 동시에 2개 존재하지 않게 한다.
  # 장중 배포 시 수십 초 공백이 생기므로 배포는 장 마감 후에 한다.
  deployment_minimum_healthy_percent = 0
  deployment_maximum_percent         = 100

  deployment_circuit_breaker {
    enable   = true
    rollback = true
  }

  propagate_tags          = "SERVICE"
  enable_ecs_managed_tags = true

  depends_on = [
    aws_ecs_cluster_capacity_providers.main,
    aws_iam_role_policy_attachment.market_streamer_valkey,
  ]
}
