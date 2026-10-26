# The production frontend service is already running in ECS.
# Pin the deployed image digest so a plain Terraform plan preserves it.
variable "frontend_enabled" {
  type        = bool
  default     = true
  description = "Run V2 frontend tasks without changing the public DNS or ALB default action"
}

variable "frontend_image" {
  type        = string
  default     = "250832562715.dkr.ecr.ap-northeast-2.amazonaws.com/stockspoon-v2-prod-frontend@sha256:2d955cddd25e70e496e4e17fc0fff32a457b3b83d56be69596a915c9d4739a6d"
  description = "Production FE image URI pinned by sha256 digest; must match the assets uploaded to S3"
  validation {
    condition     = !var.frontend_enabled || can(regex("^[0-9]{12}\\.dkr\\.ecr\\.ap-northeast-2\\.amazonaws\\.com/stockspoon-v2-prod-frontend@sha256:[0-9a-f]{64}$", var.frontend_image))
    error_message = "An enabled frontend requires a production private ECR image pinned by sha256 digest."
  }
}

variable "frontend_desired_count" {
  type        = number
  default     = 2
  description = "Frontend replicas; two for availability, subject to existing EC2/ENI capacity"
  validation {
    condition     = var.frontend_desired_count >= 1 && floor(var.frontend_desired_count) == var.frontend_desired_count
    error_message = "Use a positive integer replica count."
  }
}

resource "aws_cloudwatch_log_group" "frontend" {
  count             = var.frontend_enabled ? 1 : 0
  name              = "/ecs/${var.name_prefix}/frontend"
  retention_in_days = var.container_log_retention_days
}

resource "aws_iam_role" "frontend_task" {
  count              = var.frontend_enabled ? 1 : 0
  name               = "${var.name_prefix}-frontend-task-role"
  assume_role_policy = data.aws_iam_policy_document.ecs_tasks_assume_role.json
  # Application has no AWS API permissions.
}

resource "aws_security_group" "frontend_task" {
  count       = var.frontend_enabled ? 1 : 0
  name        = "${var.name_prefix}-frontend-task-sg"
  description = "Next.js frontend; ingress only from the existing ALB"
  vpc_id      = data.terraform_remote_state.shared.outputs.vpc_id
}

resource "aws_vpc_security_group_ingress_rule" "frontend_from_alb" {
  count                        = var.frontend_enabled ? 1 : 0
  security_group_id            = aws_security_group.frontend_task[0].id
  referenced_security_group_id = data.terraform_remote_state.app.outputs.alb_security_group_id
  from_port                    = 3000
  to_port                      = 3000
  ip_protocol                  = "tcp"
}

resource "aws_vpc_security_group_egress_rule" "alb_to_frontend" {
  count                        = var.frontend_enabled ? 1 : 0
  security_group_id            = data.terraform_remote_state.app.outputs.alb_security_group_id
  referenced_security_group_id = aws_security_group.frontend_task[0].id
  from_port                    = 3000
  to_port                      = 3000
  ip_protocol                  = "tcp"
}

resource "aws_vpc_security_group_egress_rule" "frontend_https" {
  count             = var.frontend_enabled ? 1 : 0
  security_group_id = aws_security_group.frontend_task[0].id
  cidr_ipv4         = "0.0.0.0/0"
  from_port         = 443
  to_port           = 443
  ip_protocol       = "tcp"
}

resource "aws_lb_target_group" "frontend" {
  count                = var.frontend_enabled ? 1 : 0
  name                 = "${var.name_prefix}-fe"
  port                 = 3000
  protocol             = "HTTP"
  target_type          = "ip"
  vpc_id               = data.terraform_remote_state.shared.outputs.vpc_id
  deregistration_delay = 30
  health_check {
    path                = "/health"
    matcher             = "200"
    interval            = 15
    timeout             = 5
    healthy_threshold   = 2
    unhealthy_threshold = 3
  }
}

resource "aws_lb_listener_rule" "frontend" {
  count        = var.frontend_enabled ? 1 : 0
  listener_arn = data.terraform_remote_state.app.outputs.https_listener_arn
  priority     = 300
  action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.frontend[0].arn
  }
  condition {
    path_pattern {
      values = ["/*"]
    }
  }
  lifecycle {
    precondition {
      condition     = var.backend_canary_rule_priority < 300 && var.market_http_rule_priority < 300
      error_message = "API/market listener rules must precede the frontend rule at priority 300."
    }
  }
}

resource "aws_ecs_task_definition" "frontend" {
  count        = var.frontend_enabled ? 1 : 0
  skip_destroy = true

  # Frontend releases are owned by the frontend CD pipeline after bootstrap.
  # Keep Terraform from replacing its seed task definition when CD registers
  # newer immutable image revisions.
  lifecycle {
    ignore_changes = [container_definitions]
  }

  family                   = "${var.name_prefix}-frontend"
  network_mode             = "awsvpc"
  requires_compatibilities = ["EC2"]
  cpu                      = 256
  memory                   = 512
  execution_role_arn       = aws_iam_role.ecs_task_execution.arn
  task_role_arn            = aws_iam_role.frontend_task[0].arn
  runtime_platform {
    operating_system_family = "LINUX"
    cpu_architecture        = "X86_64"
  }
  container_definitions = jsonencode([{
    name      = "frontend"
    image     = var.frontend_image
    essential = true
    cpu       = 256
    memory    = 512
    environment = concat([
      { name = "NODE_ENV", value = "production" },
      { name = "HOSTNAME", value = "0.0.0.0" },
      { name = "PORT", value = "3000" },
      ], local.telemetry_otlp_environment,
    var.plg_tempo_enabled ? [{ name = "OTEL_SERVICE_NAME", value = "frontend" }] : [])
    portMappings = [{ containerPort = 3000, protocol = "tcp" }]
    stopTimeout  = 30
    logConfiguration = {
      logDriver = "awslogs"
      options = {
        awslogs-group         = aws_cloudwatch_log_group.frontend[0].name
        awslogs-region        = var.aws_region
        awslogs-stream-prefix = "frontend"
      }
    }
  }])
}

resource "aws_ecs_service" "frontend" {
  count                              = var.frontend_enabled ? 1 : 0
  name                               = "${var.name_prefix}-frontend"
  cluster                            = aws_ecs_cluster.main.id
  task_definition                    = aws_ecs_task_definition.frontend[0].arn
  desired_count                      = var.frontend_desired_count
  health_check_grace_period_seconds  = 60
  deployment_minimum_healthy_percent = 100
  deployment_maximum_percent         = 200
  capacity_provider_strategy {
    capacity_provider = aws_ecs_capacity_provider.service.name
    weight            = 1
  }
  network_configuration {
    subnets          = data.terraform_remote_state.shared.outputs.private_subnet_ids
    security_groups  = [aws_security_group.frontend_task[0].id]
    assign_public_ip = false
  }
  load_balancer {
    target_group_arn = aws_lb_target_group.frontend[0].arn
    container_name   = "frontend"
    container_port   = 3000
  }
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
    # Image releases are owned by FE CD after the first deployment.
    ignore_changes = [task_definition]
  }
  depends_on = [
    aws_lb_listener_rule.frontend,
    aws_ecs_cluster_capacity_providers.main,
    aws_vpc_security_group_ingress_rule.frontend_from_alb,
    aws_vpc_security_group_egress_rule.alb_to_frontend,
  ]
}

resource "aws_iam_role" "frontend_deploy" {
  count = var.frontend_enabled ? 1 : 0
  name  = "${var.name_prefix}-frontend-deploy"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Action    = "sts:AssumeRoleWithWebIdentity"
      Principal = { Federated = data.terraform_remote_state.app.outputs.github_actions_oidc_provider_arn }
      Condition = { StringEquals = {
        "token.actions.githubusercontent.com:aud" = "sts.amazonaws.com"
        "token.actions.githubusercontent.com:sub" = try(data.terraform_remote_state.app.outputs.frontend_deployment_contract.oidc_subject, "")
      } }
    }]
  })
  lifecycle {
    precondition {
      condition     = can(data.terraform_remote_state.app.outputs.frontend_deployment_contract.oidc_subject)
      error_message = "Deploy the app-server frontend_deployment_contract output through CI before enabling the ECS frontend."
    }
  }
}

resource "aws_iam_role_policy" "frontend_deploy" {
  count = var.frontend_enabled ? 1 : 0
  name  = "deploy-frontend-only"
  role  = aws_iam_role.frontend_deploy[0].id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      { Effect = "Allow", Action = ["ecs:DescribeTaskDefinition", "ecs:RegisterTaskDefinition"], Resource = "*" },
      { Effect = "Allow", Action = ["ecs:DescribeServices", "ecs:UpdateService"], Resource = aws_ecs_service.frontend[0].arn },
      {
        Effect    = "Allow"
        Action    = "iam:PassRole"
        Resource  = [aws_iam_role.ecs_task_execution.arn, aws_iam_role.frontend_task[0].arn]
        Condition = { StringEquals = { "iam:PassedToService" = "ecs-tasks.amazonaws.com" } }
      },
    ]
  })
}

output "frontend_deployment" {
  value = var.frontend_enabled ? {
    cluster         = aws_ecs_cluster.main.name
    service         = aws_ecs_service.frontend[0].name
    task_family     = aws_ecs_task_definition.frontend[0].family
    deploy_role_arn = aws_iam_role.frontend_deploy[0].arn
    target_group    = aws_lb_target_group.frontend[0].arn
  } : null
}
