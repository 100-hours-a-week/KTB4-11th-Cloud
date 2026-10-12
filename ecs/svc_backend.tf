# Backend 서비스 전용 리소스
# Target Group, Task Definition, ECS Service는 다음 이슈에서 이 파일에 추가한다.

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

resource "aws_lb_target_group" "backend_green" {
  name                 = "${var.name_prefix}-backend-green"
  port                 = var.backend_container_port
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
      image       = var.backend_container_image
      essential   = true
      stopTimeout = var.backend_stop_timeout_seconds

      portMappings = [
        {
          containerPort = var.backend_container_port
          protocol      = "tcp"
        }
      ]

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
  depends_on = [
    aws_lb_listener_rule.backend_test,
    aws_ecs_cluster_capacity_providers.main,
  ]
}
