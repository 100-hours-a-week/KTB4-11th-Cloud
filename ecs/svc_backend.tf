# Backend 서비스 전용 리소스
# DB 접속은 ProxySQL ECS task를 경유한다.

locals {
  backend_image       = "${data.terraform_remote_state.app.outputs.public_ecr_v2_backend_repository_uri}:${var.backend_image_tag}"
  backend_valkey_role = "backend"

  # Keep Backend on the stable Fargate ProxySQL Cloud Map endpoint in every Terraform run.
  backend_datasource_url = "jdbc:mysql://${local.backend_proxysql_dns_name}:${var.proxysql_port}/${var.backend_mysql_database}?useSSL=false&allowPublicKeyRetrieval=true&serverTimezone=Asia/Seoul&characterEncoding=UTF-8"

  backend_environment = concat(
    [
      { name = "SPRING_PROFILES_ACTIVE", value = "prod" },
      { name = "JAVA_TOOL_OPTIONS", value = "-XX:MaxRAMPercentage=75" },

      { name = "SPRING_DATASOURCE_DRIVER_CLASS_NAME", value = "com.mysql.cj.jdbc.Driver" },
      # 스키마 변경·검증 안 함 (DB 이관 중 V1 스키마 고정)
      { name = "JPA_DDL_AUTO", value = "none" },
      { name = "SPRING_JPA_HIBERNATE_DDL_AUTO", value = "none" },

      # 운영 Valkey (IAM 인증: cluster mode + TLS 필수)
      { name = "REDIS_HOST", value = local.valkey_endpoint },
      { name = "REDIS_PORT", value = tostring(local.valkey_port) },
      { name = "REDIS_USERNAME", value = local.valkey_users[local.backend_valkey_role] },
      { name = "REDIS_SSL", value = "true" },
      { name = "REDIS_CLUSTER_MODE", value = "true" },
      { name = "ELASTICACHE_CACHE_NAME", value = local.valkey_cache_name },
      { name = "AWS_REGION", value = var.aws_region },

      { name = "AUTH_COOKIE_SECURE", value = "true" },

      # 키움 시세 스트림: V1과 별도 키(SSM KIWOOM_APP_KEY·KIWOOM_APP_SECRET)를 써서 세션 충돌은 없다.
      # V1과 같은 PENDING 지정가 주문을 함께 체결하려 해도 executeLimit이 계좌 행 FOR UPDATE 후 PENDING을 재확인하므로 한쪽만 체결된다.
      { name = "KIWOOM_STREAM_ENABLED", value = tostring(var.backend_kiwoom_stream_enabled) },
      # collector는 V1 운영 서버가 담당한다.
      { name = "KIWOOM_COLLECTOR_ENABLED", value = "false" },
    ],
    # SSM에는 빈 값을 저장할 수 없음
    var.backend_kakao_client_secret_enabled ? [] : [{ name = "KAKAO_CLIENT_SECRET", value = "" }],
  )

  # SSM /stockspoon/v2/prod/backend/<이름> (application secrets)
  backend_secret_names = concat(
    ["MYSQL_USER", "MYSQL_PASSWORD", "JWT_SECRET", "KAKAO_CLIENT_ID", "KAKAO_REDIRECT_URI", "FRONTEND_ORIGIN"],
    var.backend_kakao_client_secret_enabled ? ["KAKAO_CLIENT_SECRET"] : [],
    var.backend_kiwoom_stream_enabled ? ["KIWOOM_APP_KEY", "KIWOOM_APP_SECRET"] : [],
  )
}

# The JDBC URL is not a credential, so store it as a plain String parameter.
resource "aws_ssm_parameter" "backend_datasource_url" {
  name        = "${var.ssm_parameter_path_prefix}/backend/SPRING_DATASOURCE_URL"
  description = "JDBC URL for the V2 backend through the migration rehearsal ProxySQL task"
  type        = "String"
  value       = local.backend_datasource_url

  lifecycle {
    precondition {
      condition     = var.proxysql_fargate_enabled
      error_message = "The Backend datasource is pinned to Fargate ProxySQL; keep proxysql_fargate_enabled=true."
    }
  }
}

# ---------------------------------------------------------------------------
# Logs
# ---------------------------------------------------------------------------

resource "aws_cloudwatch_log_group" "backend" {
  name              = "/ecs/${var.name_prefix}/backend"
  retention_in_days = var.container_log_retention_days
}

# ---------------------------------------------------------------------------
# Task Role
# 애플리케이션 코드가 AWS API를 호출할 때 사용한다.
# 지금은 권한 없이 만들고, 운영 SQS 등 필요한 권한은 해당 리소스를 만들 때 추가한다.
# ---------------------------------------------------------------------------

resource "aws_iam_role" "backend_task" {
  name               = "${var.name_prefix}-backend-task-role"
  description        = "Role assumed by the backend application containers"
  assume_role_policy = data.aws_iam_policy_document.ecs_tasks_assume_role.json
}

# 운영 Valkey IAM 인증 (backend 사용자)
resource "aws_iam_role_policy_attachment" "backend_valkey" {
  role       = aws_iam_role.backend_task.name
  policy_arn = local.valkey_policies[local.backend_valkey_role]
}

# Lets the BE publish failed writes to the queue managed by the messaging root.
# Apply messaging/prod before this ECS root so the policy output exists.
resource "aws_iam_role_policy_attachment" "backend_db_write_replay_sqs" {
  role       = aws_iam_role.backend_task.name
  policy_arn = data.terraform_remote_state.messaging_prod.outputs.backend_db_write_replay_producer_policy_arn
}

# ---------------------------------------------------------------------------
# Security Group
# ---------------------------------------------------------------------------

# ALB에서 오는 트래픽만 받는다. (awsvpc: Task ENI에 직접 적용)
resource "aws_security_group" "backend_task" {
  name        = "${var.name_prefix}-backend-task-sg"
  description = "Backend ECS tasks (inbound only from the ALB)"
  vpc_id      = data.terraform_remote_state.shared.outputs.vpc_id

  tags = {
    Name = "${var.name_prefix}-backend-task-sg"
  }
}

resource "aws_vpc_security_group_ingress_rule" "backend_task_from_alb" {
  security_group_id            = aws_security_group.backend_task.id
  referenced_security_group_id = data.terraform_remote_state.app.outputs.alb_security_group_id
  from_port                    = var.backend_container_port
  to_port                      = var.backend_container_port
  ip_protocol                  = "tcp"
  description                  = "Allow application traffic and health checks from the ALB"
}

# DB, Redis, SQS, 외부 API 등 (NAT 경유)
resource "aws_vpc_security_group_egress_rule" "backend_task_all" {
  security_group_id = aws_security_group.backend_task.id
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "-1"
  description       = "Allow outbound to dependencies"
}

# ---------------------------------------------------------------------------
# Target Group (Green)
# ---------------------------------------------------------------------------

# port는 ip 타입에서 기본값일 뿐이다. (실제 트래픽·헬스체크는 ECS 등록 포트 8080)
# ForceNew + 고정 이름이라 교체 시 실패하므로 80을 유지한다.
resource "aws_lb_target_group" "backend_green" {
  name                 = "${var.name_prefix}-backend-green"
  port                 = 80
  protocol             = "HTTP"
  target_type          = "ip"
  vpc_id               = data.terraform_remote_state.shared.outputs.vpc_id
  deregistration_delay = var.backend_deregistration_delay_seconds

  health_check {
    enabled             = true
    protocol            = "HTTP"
    path                = var.backend_health_check_path
    matcher             = "200"
    interval            = 10
    timeout             = 5
    healthy_threshold   = 2
    unhealthy_threshold = 2
  }

  tags = {
    Name = "${var.name_prefix}-backend-green"
  }
}

# ---------------------------------------------------------------------------
# Task Definition
# ---------------------------------------------------------------------------

resource "aws_ecs_task_definition" "backend" {
  skip_destroy = true

  lifecycle {
    ignore_changes = [
      family, network_mode, requires_compatibilities, cpu, memory,
      execution_role_arn, task_role_arn, runtime_platform, container_definitions,
    ]
  }

  family                   = "${var.name_prefix}-backend"
  network_mode             = "awsvpc"
  requires_compatibilities = ["EC2"]
  cpu                      = var.backend_task_cpu
  memory                   = var.backend_task_memory
  execution_role_arn       = aws_iam_role.ecs_task_execution.arn
  task_role_arn            = aws_iam_role.backend_task.arn

  runtime_platform {
    operating_system_family = "LINUX"
    cpu_architecture        = "X86_64"
  }

  container_definitions = jsonencode([
    {
      name        = "backend"
      image       = local.backend_image
      essential   = true
      stopTimeout = var.backend_stop_timeout_seconds

      portMappings = [
        {
          containerPort = var.backend_container_port
          protocol      = "tcp"
        }
      ]

      # 최초 생성 시점의 SSM 버전 기록용이다. container_definitions는 ignore_changes 대상이라
      # SSM 값이 바뀌어도 Terraform은 새 리비전을 만들지 않는다. SSM 값은 Task 시작 시에만 읽으므로
      # 변경 후에는 BE CD 재배포 또는 aws ecs update-service --force-new-deployment로 Task를 교체한다.
      environment = concat(
        local.backend_environment,
        [{
          name  = "TF_DATASOURCE_URL_PARAMETER_VERSION"
          value = tostring(aws_ssm_parameter.backend_datasource_url.version)
        }]
      )

      secrets = concat(
        [
          for name in local.backend_secret_names : {
            name      = name
            valueFrom = "arn:${local.partition}:ssm:${var.aws_region}:${local.account_id}:parameter${var.ssm_parameter_path_prefix}/backend/${name}"
          }
        ],
        [
          {
            name      = "SPRING_DATASOURCE_URL"
            valueFrom = aws_ssm_parameter.backend_datasource_url.arn
          }
        ]
      )

      logConfiguration = {
        logDriver = "awslogs"
        options = {
          awslogs-group         = aws_cloudwatch_log_group.backend.name
          awslogs-region        = var.aws_region
          awslogs-stream-prefix = "backend"
        }
      }
    }
  ])
}

# ---------------------------------------------------------------------------
# ECS Service
# ---------------------------------------------------------------------------

resource "aws_ecs_service" "backend" {
  name            = "${var.name_prefix}-backend"
  cluster         = aws_ecs_cluster.main.id
  task_definition = aws_ecs_task_definition.backend.arn
  desired_count   = var.backend_desired_count

  capacity_provider_strategy {
    capacity_provider = aws_ecs_capacity_provider.service.name
    weight            = 1
  }

  network_configuration {
    subnets          = data.terraform_remote_state.shared.outputs.private_subnet_ids
    security_groups  = [aws_security_group.backend_task.id]
    assign_public_ip = false
  }

  load_balancer {
    target_group_arn = aws_lb_target_group.backend_green.arn
    container_name   = "backend"
    container_port   = var.backend_container_port
  }

  health_check_grace_period_seconds  = var.backend_health_check_grace_period_seconds
  deployment_minimum_healthy_percent = 100
  deployment_maximum_percent         = 200

  deployment_controller {
    type = var.backend_deployment_controller
  }

  deployment_circuit_breaker {
    enable   = true
    rollback = true
  }

  # AZ를 먼저 분산하고, 같은 AZ 안에서는 인스턴스를 분산한다.
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

  # Target Group이 리스너에 연결된 뒤에 Service를 만들어야 한다.
  # 실행 설정과 이미지 배포는 BE 레포 cd-ecs-v2.yaml이 새 리비전을 등록해 수행한다.
  # apply가 CD로 배포된 리비전을 backend_image_tag 리비전으로 되돌리지 않도록 무시한다.
  lifecycle {
    ignore_changes = [task_definition, desired_count]
  }

  depends_on = [
    aws_lb_listener_rule.backend_canary,
    aws_ecs_cluster_capacity_providers.main,
    aws_iam_role_policy_attachment.backend_valkey,
    aws_vpc_security_group_ingress_rule.v1_mysql_from_backend,
  ]
}
