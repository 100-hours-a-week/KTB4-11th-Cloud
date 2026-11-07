# The Backend uses the Fargate ProxySQL endpoint.
variable "proxysql_fargate_enabled" {
  description = "Keep the Fargate ProxySQL service required by the Backend datasource enabled"
  type        = bool
  default     = true
}

locals {
  proxysql_fargate_service_name = "${var.proxysql_dns_service_name}-fargate"
  proxysql_fargate_dns_name     = "${local.proxysql_fargate_service_name}.${var.proxysql_dns_namespace}"
  backend_proxysql_dns_name     = local.proxysql_fargate_dns_name
  proxysql_fargate_task_cpu     = var.proxysql_task_cpu
  # Leave room for the FIS SSM agent sidecar on the smallest default task.
  proxysql_fargate_task_memory = max(var.proxysql_task_memory, 2048)
  proxysql_fis_agent_container = {
    name       = "amazon-ssm-agent"
    image      = "public.ecr.aws/amazon-ssm-agent/amazon-ssm-agent:latest"
    essential  = false
    entryPoint = ["/bin/bash", "-c"]
    command    = [file("${path.module}/scripts/fis-ssm-agent.sh")]
    environment = [
      { name = "MANAGED_INSTANCE_ROLE_NAME", value = aws_iam_role.proxysql_fis_managed.name },
    ]
    cpu         = 32
    memory      = 128
    stopTimeout = 60

    logConfiguration = {
      logDriver = "awslogs"
      options = {
        awslogs-group         = aws_cloudwatch_log_group.proxysql.name
        awslogs-region        = var.aws_region
        awslogs-stream-prefix = "fis-ssm-agent"
      }
    }
  }
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
  cpu                      = local.proxysql_fargate_task_cpu
  memory                   = local.proxysql_fargate_task_memory
  execution_role_arn       = aws_iam_role.ecs_task_execution.arn
  task_role_arn            = aws_iam_role.proxysql_fargate_task.arn
  pid_mode                 = "task"
  enable_fault_injection   = true

  runtime_platform {
    operating_system_family = "LINUX"
    cpu_architecture        = "X86_64"
  }

  # Reuse the existing containers, secrets and CloudWatch group. Set the
  # Fargate health check and monitor bootstrap command explicitly.
  container_definitions = jsonencode(concat(
    [
      for container in local.proxysql_container_definitions : merge(
        container,
        {
          cpu    = container.name == "proxysql" ? local.proxysql_fargate_task_cpu - 96 : container.cpu
          memory = container.name == "proxysql" ? local.proxysql_fargate_task_memory - 256 : container.memory
        },
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
    ],
    [local.proxysql_fis_agent_container],
  ))

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
      }, tostring(local.proxysql_fargate_task_cpu), []), local.proxysql_fargate_task_memory)
      error_message = "ProxySQL CPU/memory must be a supported Fargate combination (default: 512 CPU, 2048 MiB with the FIS sidecar)."
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
  enable_execute_command             = false
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
    aws_iam_role_policy.proxysql_fargate_task_fis_registration,
    aws_iam_role_policy.proxysql_fis_managed_cleanup,
    aws_iam_role_policy_attachment.proxysql_fis_managed_core,
    aws_vpc_security_group_egress_rule.proxysql_task_https,
    aws_vpc_security_group_egress_rule.proxysql_task_to_migration_mysql,
    aws_vpc_security_group_egress_rule.proxysql_task_to_private_replica_mysql,
    aws_vpc_security_group_ingress_rule.migration_mysql_from_proxysql,
    aws_vpc_security_group_ingress_rule.private_replica_mysql_from_proxysql,
    aws_vpc_security_group_ingress_rule.proxysql_metrics_from_pmm,
    aws_vpc_security_group_egress_rule.pmm_to_proxysql_metrics,
  ]

  tags = { Name = "${var.name_prefix}-proxysql-fargate" }
}

# Keep the old public V1 application/replica host available until the new
# ProxySQL task is healthy against the Primary and private GTID replica.
# The separate state resource makes the shutdown ordering explicit.
resource "aws_ec2_instance_state" "retired_v1_app" {
  count = var.proxysql_fargate_enabled ? 1 : 0

  instance_id = data.terraform_remote_state.app.outputs.app_instance_id
  state       = "stopped"

  depends_on = [aws_ecs_service.proxysql_fargate]
}

output "proxysql_fargate" {
  description = "Production Fargate ProxySQL endpoint for the Primary and private GTID replica"
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
