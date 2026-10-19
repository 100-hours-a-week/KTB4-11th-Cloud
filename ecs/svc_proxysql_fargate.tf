# Parallel migration: leave the EC2 ProxySQL service and its DNS untouched.
# Enable this service first; switch the BE parameter only after verification.
variable "proxysql_fargate_enabled" {
  description = "Run an additional ProxySQL on Fargate for staged migration"
  type        = bool
  default     = true
}

variable "backend_proxysql_target" {
  description = "ProxySQL endpoint written to the BE SSM parameter: ec2 or fargate"
  type        = string
  default     = "ec2"

  validation {
    condition     = contains(["ec2", "fargate"], var.backend_proxysql_target)
    error_message = "backend_proxysql_target must be ec2 or fargate."
  }
}

locals {
  proxysql_fargate_service_name      = "${var.proxysql_dns_service_name}-fargate"
  proxysql_fargate_dns_name          = "${local.proxysql_fargate_service_name}.${var.proxysql_dns_namespace}"
  backend_proxysql_dns_name          = var.backend_proxysql_target == "fargate" ? local.proxysql_fargate_dns_name : local.proxysql_dns_name
  proxysql_fargate_bootstrap_command = <<-EOT
    ${local.proxysql_bootstrap_command}

    # Match the live ProxySQL read_only monitor cadence and timeout.
    mysql --defaults-extra-file=/tmp/proxysql-admin.cnf <<'MONITOR_SQL'
    UPDATE global_variables SET variable_value = '1000'
      WHERE variable_name = 'mysql-monitor_read_only_interval';
    UPDATE global_variables SET variable_value = '800'
      WHERE variable_name = 'mysql-monitor_read_only_timeout';
    LOAD MYSQL VARIABLES TO RUNTIME;
    SAVE MYSQL VARIABLES TO DISK;
    MONITOR_SQL

    echo "Fargate ProxySQL monitor settings matched: interval=1000ms timeout=800ms"

    # Expose ProxySQL's built-in Prometheus metrics endpoint on every new task.
    mysql --defaults-extra-file=/tmp/proxysql-admin.cnf <<'RESTAPI_SQL'
    SET admin-restapi_enabled = 'true';
    SET admin-restapi_port = '6070';
    LOAD ADMIN VARIABLES TO RUNTIME;
    SAVE ADMIN VARIABLES TO DISK;
    RESTAPI_SQL

    echo "Fargate ProxySQL Prometheus endpoint enabled on port 6070"
  EOT
}

resource "aws_service_discovery_service" "proxysql_fargate" {
  count = var.proxysql_fargate_enabled ? 1 : 0

  name = local.proxysql_fargate_service_name

  dns_config {
    namespace_id   = aws_service_discovery_private_dns_namespace.proxysql.id
    routing_policy = "MULTIVALUE"

    dns_records {
      ttl  = 10
      type = "A"
    }
  }

  tags = { Name = "${var.name_prefix}-proxysql-fargate" }
}

resource "aws_ecs_task_definition" "proxysql_fargate" {
  count = var.proxysql_fargate_enabled ? 1 : 0

  family                   = "${var.name_prefix}-proxysql-fargate"
  network_mode             = "awsvpc"
  requires_compatibilities = ["FARGATE"]
  cpu                      = var.proxysql_task_cpu
  memory                   = var.proxysql_task_memory
  execution_role_arn       = aws_iam_role.ecs_task_execution.arn
  task_role_arn            = aws_iam_role.proxysql_task.arn

  runtime_platform {
    operating_system_family = "LINUX"
    cpu_architecture        = "X86_64"
  }

  # Reuse the existing containers, secrets and CloudWatch group. Set the
  # Fargate health check and monitor bootstrap command explicitly.
  container_definitions = jsonencode([
    for container in jsondecode(aws_ecs_task_definition.proxysql.container_definitions) : merge(
      container,
      container.name == "proxysql" ? {
        healthCheck = {
          command     = ["CMD-SHELL", local.proxysql_healthcheck_command]
          interval    = 10
          timeout     = 5
          retries     = 6
          startPeriod = 180
        }
      } : {},
      container.name == "proxysql-bootstrap" ? {
        command = [local.proxysql_fargate_bootstrap_command]
      } : {},
    )
  ])

  lifecycle {
    precondition {
      condition = contains(lookup({
        "256"   = [512, 1024, 2048]
        "512"   = [1024, 2048, 3072, 4096]
        "1024"  = range(2048, 8193, 1024)
        "2048"  = range(4096, 16385, 1024)
        "4096"  = range(8192, 30721, 1024)
        "8192"  = range(16384, 61441, 4096)
        "16384" = range(32768, 122881, 8192)
      }, tostring(var.proxysql_task_cpu), []), var.proxysql_task_memory)
      error_message = "ProxySQL CPU/memory must be a supported Fargate combination (default: 512 CPU, 1024 MiB)."
    }
  }
}

resource "aws_ecs_service" "proxysql_fargate" {
  count = var.proxysql_fargate_enabled ? 1 : 0

  name                               = "${var.name_prefix}-proxysql-fargate"
  cluster                            = aws_ecs_cluster.main.id
  task_definition                    = aws_ecs_task_definition.proxysql_fargate[0].arn
  launch_type                        = "FARGATE"
  platform_version                   = "1.4.0"
  desired_count                      = 1
  enable_execute_command             = true
  deployment_minimum_healthy_percent = 100
  deployment_maximum_percent         = 200
  wait_for_steady_state              = true

  network_configuration {
    subnets          = local.proxysql_subnet_ids
    security_groups  = [aws_security_group.proxysql_task.id]
    assign_public_ip = false
  }

  service_registries {
    registry_arn = aws_service_discovery_service.proxysql_fargate[0].arn
  }

  deployment_circuit_breaker {
    enable   = true
    rollback = true
  }

  depends_on = [
    aws_iam_role_policy.proxysql_task_exec,
    aws_vpc_security_group_egress_rule.proxysql_task_https,
    aws_vpc_security_group_egress_rule.proxysql_task_to_v1_mysql,
    aws_vpc_security_group_egress_rule.proxysql_task_to_migration_mysql,
    aws_vpc_security_group_ingress_rule.v1_mysql_from_proxysql,
    aws_vpc_security_group_ingress_rule.migration_mysql_from_proxysql,
    aws_vpc_security_group_ingress_rule.proxysql_from_db_write_replay_lambda,
    aws_vpc_security_group_ingress_rule.proxysql_metrics_from_pmm,
    aws_vpc_security_group_egress_rule.pmm_to_proxysql_metrics,
  ]

  tags = { Name = "${var.name_prefix}-proxysql-fargate" }
}

output "proxysql_fargate" {
  description = "Parallel Fargate ProxySQL endpoint for verification before BE cutover"
  value = var.proxysql_fargate_enabled ? {
    service_name   = aws_ecs_service.proxysql_fargate[0].name
    dns_name       = local.proxysql_fargate_dns_name
    port           = var.proxysql_port
    log_group_name = aws_cloudwatch_log_group.proxysql.name
  } : null
}

output "backend_proxysql_dns_name" {
  description = "ProxySQL DNS selected for the BE SSM parameter; running tasks require redeployment to read it"
  value       = local.backend_proxysql_dns_name
}
