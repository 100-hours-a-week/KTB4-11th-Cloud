variable "backend_collector_enabled" {
  description = "Run one private REST collector using the existing BE application"
  type        = bool
  default     = true
}

variable "backend_collector_image_tag" {
  description = "Pinned BE commit for the REST collector; promote separately from ordinary BE deployments"
  type        = string
  default     = "d9d6b8c6ae3e01e027fbaba3df6286347ef65e5a"

  validation {
    condition     = can(regex("^[0-9a-f]{40}$", var.backend_collector_image_tag))
    error_message = "Use a full BE commit SHA for the collector image."
  }
}

locals {
  backend_collector_name       = "${var.name_prefix}-backend-collector"
  backend_collector_url        = "http://backend-collector.${var.proxysql_dns_namespace}:${var.backend_container_port}"
  backend_collector_secret_arn = "arn:${local.partition}:ssm:${var.aws_region}:${local.account_id}:parameter${var.ssm_parameter_path_prefix}/backend/KIWOOM_COLLECTOR_SECRET"
}

# The shared secret is initialized out of Terraform and is never put in state.
resource "aws_ssm_parameter" "backend_collector_url" {
  count       = var.backend_collector_enabled ? 1 : 0
  name        = "${var.ssm_parameter_path_prefix}/backend/KIWOOM_COLLECTOR_URL"
  description = "Private REST collector URL used by the ordinary BE tasks"
  type        = "String"
  value       = local.backend_collector_url
}

resource "aws_cloudwatch_log_group" "backend_collector" {
  count             = var.backend_collector_enabled ? 1 : 0
  name              = "/ecs/${var.name_prefix}/backend-collector"
  retention_in_days = var.container_log_retention_days
}

resource "aws_security_group" "backend_collector" {
  count       = var.backend_collector_enabled ? 1 : 0
  name        = "${local.backend_collector_name}-sg"
  description = "Private BE REST collector; no ALB or public ingress"
  vpc_id      = data.terraform_remote_state.shared.outputs.vpc_id
  tags        = { Name = "${local.backend_collector_name}-sg" }
}

resource "aws_vpc_security_group_ingress_rule" "backend_collector_from_backend" {
  count                        = var.backend_collector_enabled ? 1 : 0
  security_group_id            = aws_security_group.backend_collector[0].id
  referenced_security_group_id = aws_security_group.backend_task.id
  from_port                    = var.backend_container_port
  to_port                      = var.backend_container_port
  ip_protocol                  = "tcp"
  description                  = "Allow internal REST requests only from ordinary BE tasks"
}

resource "aws_vpc_security_group_egress_rule" "backend_collector" {
  count             = var.backend_collector_enabled ? 1 : 0
  security_group_id = aws_security_group.backend_collector[0].id
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "-1"
  description       = "Reach existing dependencies and Kiwoom REST through the NAT gateway"
}

# The same application still initializes JPA. Its datasource stays unchanged.
resource "aws_vpc_security_group_ingress_rule" "proxysql_from_backend_collector" {
  count                        = var.backend_collector_enabled ? 1 : 0
  security_group_id            = aws_security_group.proxysql_task.id
  referenced_security_group_id = aws_security_group.backend_collector[0].id
  from_port                    = var.proxysql_port
  to_port                      = var.proxysql_port
  ip_protocol                  = "tcp"
  description                  = "Allow the collector application to use the existing ProxySQL endpoint"
}

resource "aws_service_discovery_service" "backend_collector" {
  count = var.backend_collector_enabled ? 1 : 0
  name  = "backend-collector"

  dns_config {
    namespace_id   = aws_service_discovery_private_dns_namespace.proxysql.id
    routing_policy = "MULTIVALUE"
    dns_records {
      ttl  = 10
      type = "A"
    }
  }

  tags = { Name = local.backend_collector_name }
}

resource "aws_ecs_task_definition" "backend_collector" {
  count                    = var.backend_collector_enabled ? 1 : 0
  skip_destroy             = true
  family                   = local.backend_collector_name
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

  container_definitions = jsonencode([{
    name        = "backend"
    image       = "${data.terraform_remote_state.app.outputs.public_ecr_v2_backend_repository_uri}:${var.backend_collector_image_tag}"
    essential   = true
    stopTimeout = var.backend_stop_timeout_seconds
    portMappings = [{
      containerPort = var.backend_container_port
      protocol      = "tcp"
    }]
    environment = concat(
      [for item in local.backend_environment : item if !contains(["KIWOOM_COLLECTOR_ENABLED", "KIWOOM_STREAM_ENABLED"], item.name)],
      [
        { name = "KIWOOM_COLLECTOR_ENABLED", value = "true" },
        { name = "KIWOOM_STREAM_ENABLED", value = "false" },
        { name = "COMPETITION_START_ENABLED", value = "false" },
        { name = "COMPETITION_COMPLETION_ENABLED", value = "false" },
      ]
    )
    secrets = concat(
      [for name in distinct(concat(local.backend_secret_names, ["KIWOOM_APP_KEY", "KIWOOM_APP_SECRET"])) : {
        name      = name
        valueFrom = "arn:${local.partition}:ssm:${var.aws_region}:${local.account_id}:parameter${var.ssm_parameter_path_prefix}/${contains(["KIWOOM_APP_KEY", "KIWOOM_APP_SECRET"], name) ? "backend-collector" : "backend"}/${name}"
      }],
      [{ name = "SPRING_DATASOURCE_URL", valueFrom = aws_ssm_parameter.backend_datasource_url.arn }]
    )
    healthCheck = {
      command     = ["CMD-SHELL", "bash -ec 'exec 3<>/dev/tcp/127.0.0.1/${var.backend_container_port}; printf \"GET /actuator/health HTTP/1.1\\r\\nHost: localhost\\r\\nConnection: close\\r\\n\\r\\n\" >&3; IFS= read -r status <&3; [[ \"$status\" == *\" 200 \"* ]]'"]
      interval    = 15
      timeout     = 5
      retries     = 3
      startPeriod = 120
    }
    logConfiguration = {
      logDriver = "awslogs"
      options = {
        awslogs-group         = aws_cloudwatch_log_group.backend_collector[0].name
        awslogs-region        = var.aws_region
        awslogs-stream-prefix = "backend-collector"
      }
    }
  }])
}

resource "aws_ecs_service" "backend_collector" {
  count           = var.backend_collector_enabled ? 1 : 0
  name            = local.backend_collector_name
  cluster         = aws_ecs_cluster.main.id
  task_definition = aws_ecs_task_definition.backend_collector[0].arn
  desired_count   = 1

  capacity_provider_strategy {
    capacity_provider = aws_ecs_capacity_provider.service.name
    weight            = 1
  }

  network_configuration {
    subnets          = data.terraform_remote_state.shared.outputs.private_subnet_ids
    security_groups  = [aws_security_group.backend_collector[0].id]
    assign_public_ip = false
  }

  service_registries {
    registry_arn = aws_service_discovery_service.backend_collector[0].arn
  }

  # The application rejects a second owner at startup. Stop the old task first.
  deployment_minimum_healthy_percent = 0
  deployment_maximum_percent         = 100
  deployment_circuit_breaker {
    enable   = true
    rollback = true
  }

  propagate_tags = "SERVICE"
  tags           = { Name = local.backend_collector_name }

  depends_on = [
    aws_ecs_cluster_capacity_providers.main,
    aws_iam_role_policy_attachment.backend_valkey,
    aws_iam_role_policy.ecs_task_execution_secrets,
    aws_vpc_security_group_ingress_rule.backend_collector_from_backend,
    aws_vpc_security_group_ingress_rule.proxysql_from_backend_collector,
    aws_vpc_security_group_egress_rule.backend_collector,
    aws_ssm_parameter.backend_collector_url,
  ]
}

output "backend_collector" {
  value = var.backend_collector_enabled ? {
    service_name      = aws_ecs_service.backend_collector[0].name
    url               = local.backend_collector_url
    log_group         = aws_cloudwatch_log_group.backend_collector[0].name
    shared_secret_arn = local.backend_collector_secret_arn
    deployment_mode   = "stop-first; REST cache misses may fail while replacing the singleton"
  } : null
}
