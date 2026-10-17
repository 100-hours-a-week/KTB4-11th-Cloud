# DB migration rehearsal ProxySQL service.
# A bootstrap sidecar reapplies routing configuration on every fresh ECS task.

locals {
  proxysql_subnet_ids = [data.terraform_remote_state.shared.outputs.private_subnet_ids[0]]
  proxysql_dns_name   = "${var.proxysql_dns_service_name}.${var.proxysql_dns_namespace}"

  proxysql_v1_mysql_host        = data.terraform_remote_state.app.outputs.app_private_ip
  proxysql_migration_mysql_host = try(data.terraform_remote_state.app.outputs.db_migration_host.private_ip, "")
  proxysql_migration_mysql_sg   = try(data.terraform_remote_state.app.outputs.db_migration_host.security_group_id, "")
  proxysql_monitor_password_arn = "arn:${local.partition}:ssm:${var.aws_region}:${local.account_id}:parameter${var.ssm_parameter_path_prefix}/backend/PROXYSQL_MONITOR_PASSWORD"

  # ProxySQL starts with an empty config database, then this sidecar sets the
  # servers, app user, read_only monitoring, and writer/reader hostgroups.
  proxysql_bootstrap_command = <<-EOT
    set -eu

    if [ -z "$PROXYSQL_MIGRATION_HOST" ]; then
      echo "ERROR: migration MySQL host is missing from Terraform remote state" >&2
      exit 1
    fi
    : "$PROXYSQL_APP_USER"
    : "$PROXYSQL_APP_PASSWORD"
    : "$PROXYSQL_MONITOR_PASSWORD"

    cat > /tmp/proxysql-admin.cnf <<'ADMIN'
    [client]
    user=admin
    password=admin
    protocol=tcp
    host=127.0.0.1
    port=6032
    ADMIN
    chmod 0600 /tmp/proxysql-admin.cnf

    attempt=0
    until mysql --defaults-extra-file=/tmp/proxysql-admin.cnf -Nse 'SELECT 1' >/dev/null 2>&1; do
      attempt=$((attempt + 1))
      if [ "$attempt" -ge 60 ]; then
        echo "ERROR: ProxySQL Admin interface did not become ready" >&2
        exit 1
      fi
      sleep 2
    done

    # Escape SQL string literals without printing credential values to logs.
    sql_escape() {
      printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e "s/'/''/g"
    }
    app_user_sql=$(sql_escape "$PROXYSQL_APP_USER")
    app_password_sql=$(sql_escape "$PROXYSQL_APP_PASSWORD")
    monitor_user_sql=$(sql_escape "$PROXYSQL_MONITOR_USER")
    monitor_password_sql=$(sql_escape "$PROXYSQL_MONITOR_PASSWORD")

    mysql --defaults-extra-file=/tmp/proxysql-admin.cnf <<SQL
    DELETE FROM mysql_servers
      WHERE hostname IN ('${local.proxysql_v1_mysql_host}', '${local.proxysql_migration_mysql_host}');
    INSERT INTO mysql_servers (hostgroup_id, hostname, port, comment) VALUES
      (10, '${local.proxysql_v1_mysql_host}', ${var.v1_mysql_port}, 'V1 primary candidate'),
      (20, '${local.proxysql_migration_mysql_host}', ${var.v1_mysql_port}, 'Migration replica candidate');

    DELETE FROM mysql_replication_hostgroups
      WHERE writer_hostgroup = 10 OR reader_hostgroup = 20;
    INSERT INTO mysql_replication_hostgroups (writer_hostgroup, reader_hostgroup, check_type, comment)
      VALUES (10, 20, 'read_only', 'V1 and migration DB');

    DELETE FROM mysql_users WHERE username = '$app_user_sql';
    INSERT INTO mysql_users
      (username, password, default_hostgroup, active, frontend, backend, transaction_persistent)
      VALUES ('$app_user_sql', '$app_password_sql', 10, 1, 1, 1, 1);

    UPDATE global_variables SET variable_value = '$monitor_user_sql'
      WHERE variable_name = 'mysql-monitor_username';
    UPDATE global_variables SET variable_value = '$monitor_password_sql'
      WHERE variable_name = 'mysql-monitor_password';
    UPDATE global_variables SET variable_value = 'false'
      WHERE variable_name = 'mysql-monitor_writer_is_also_reader';

    LOAD MYSQL VARIABLES TO RUNTIME;
    LOAD MYSQL SERVERS TO RUNTIME;
    LOAD MYSQL USERS TO RUNTIME;
    SAVE MYSQL VARIABLES TO DISK;
    SAVE MYSQL SERVERS TO DISK;
    SAVE MYSQL USERS TO DISK;
    SQL

    echo "ProxySQL bootstrap completed for V1 and migration MySQL"
  EOT

  proxysql_healthcheck_command = "mysql --defaults-extra-file=/tmp/proxysql-admin.cnf -Nse \"SELECT IF((SELECT COUNT(*) FROM runtime_mysql_servers WHERE hostname IN ('${local.proxysql_v1_mysql_host}', '${local.proxysql_migration_mysql_host}') AND status = 'ONLINE') = 2 AND (SELECT COUNT(*) FROM runtime_mysql_replication_hostgroups WHERE writer_hostgroup = 10 AND reader_hostgroup = 20) = 1 AND (SELECT COUNT(DISTINCT username) FROM runtime_mysql_users) >= 1, 1, 0)\" | grep -qx '1'"

  proxysql_network_check_command = join("\n", concat(
    [
      "status=0",
      "if nc -z -w 3 ${local.proxysql_v1_mysql_host} ${var.v1_mysql_port}; then",
      "  echo TCP_OK V1 ${local.proxysql_v1_mysql_host}:${var.v1_mysql_port}",
      "else",
      "  echo TCP_FAIL V1 ${local.proxysql_v1_mysql_host}:${var.v1_mysql_port}",
      "  status=1",
      "fi",
    ],
    local.proxysql_migration_mysql_host == "" ? [] : [
      "if nc -z -w 3 ${local.proxysql_migration_mysql_host} ${var.v1_mysql_port}; then",
      "  echo TCP_OK MIGRATION ${local.proxysql_migration_mysql_host}:${var.v1_mysql_port}",
      "else",
      "  echo TCP_FAIL MIGRATION ${local.proxysql_migration_mysql_host}:${var.v1_mysql_port}",
      "  status=1",
      "fi",
    ],
    ["exit $status"],
  ))
}

resource "aws_cloudwatch_log_group" "proxysql" {
  name              = "/ecs/${var.name_prefix}/proxysql"
  retention_in_days = var.container_log_retention_days
}

# ECS task private IPs can change on replacement. Cloud Map keeps a stable
# in-VPC DNS name and updates its A record as the service task is registered.
resource "aws_service_discovery_private_dns_namespace" "proxysql" {
  name        = var.proxysql_dns_namespace
  description = "Private DNS namespace for the V2 migration rehearsal"
  vpc         = data.terraform_remote_state.shared.outputs.vpc_id

  tags = {
    Name = "${var.name_prefix}-service-discovery"
  }
}

resource "aws_service_discovery_service" "proxysql" {
  name = var.proxysql_dns_service_name

  # ECS updates the Cloud Map health state from the container health check.
  health_check_custom_config {}

  dns_config {
    namespace_id   = aws_service_discovery_private_dns_namespace.proxysql.id
    routing_policy = "MULTIVALUE"

    dns_records {
      ttl  = 10
      type = "A"
    }
  }

  tags = {
    Name = "${var.name_prefix}-proxysql"
  }
}

resource "aws_iam_role" "proxysql_task" {
  name               = "${var.name_prefix}-proxysql-task-role"
  description        = "Task role for ECS Exec into the ProxySQL rehearsal task"
  assume_role_policy = data.aws_iam_policy_document.ecs_tasks_assume_role.json
}

# ECS Exec opens its control/data channels through ssmmessages.
resource "aws_iam_role_policy" "proxysql_task_exec" {
  name = "${var.name_prefix}-proxysql-task-exec"
  role = aws_iam_role.proxysql_task.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Action = [
        "ssmmessages:CreateControlChannel",
        "ssmmessages:CreateDataChannel",
        "ssmmessages:OpenControlChannel",
        "ssmmessages:OpenDataChannel",
      ]
      Resource = "*"
    }]
  })
}

resource "aws_security_group" "proxysql_task" {
  name        = "${var.name_prefix}-proxysql-task-sg"
  description = "ProxySQL ECS task for MySQL network reachability checks"
  vpc_id      = data.terraform_remote_state.shared.outputs.vpc_id

  tags = {
    Name = "${var.name_prefix}-proxysql-task-sg"
  }
}

resource "aws_vpc_security_group_egress_rule" "proxysql_task_to_v1_mysql" {
  security_group_id            = aws_security_group.proxysql_task.id
  referenced_security_group_id = data.terraform_remote_state.app.outputs.app_security_group_id
  from_port                    = var.v1_mysql_port
  to_port                      = var.v1_mysql_port
  ip_protocol                  = "tcp"
  description                  = "Allow ProxySQL network checks and later proxy traffic to V1 MySQL"
}

resource "aws_vpc_security_group_egress_rule" "proxysql_task_https" {
  security_group_id = aws_security_group.proxysql_task.id
  cidr_ipv4         = "0.0.0.0/0"
  from_port         = 443
  to_port           = 443
  ip_protocol       = "tcp"
  description       = "Allow ECS Exec SSM message channels through the existing NAT route"
}

resource "aws_vpc_security_group_egress_rule" "proxysql_task_to_migration_mysql" {
  count = local.proxysql_migration_mysql_sg == "" ? 0 : 1

  security_group_id            = aws_security_group.proxysql_task.id
  referenced_security_group_id = local.proxysql_migration_mysql_sg
  from_port                    = var.v1_mysql_port
  to_port                      = var.v1_mysql_port
  ip_protocol                  = "tcp"
  description                  = "Allow ProxySQL network checks and later proxy traffic to the migration MySQL"
}

resource "aws_vpc_security_group_ingress_rule" "migration_mysql_from_proxysql" {
  count = local.proxysql_migration_mysql_sg == "" ? 0 : 1

  security_group_id            = local.proxysql_migration_mysql_sg
  referenced_security_group_id = aws_security_group.proxysql_task.id
  from_port                    = var.v1_mysql_port
  to_port                      = var.v1_mysql_port
  ip_protocol                  = "tcp"
  description                  = "Allow the ProxySQL ECS task to reach the migration MySQL"
}

resource "aws_ecs_task_definition" "proxysql" {
  family                   = "${var.name_prefix}-proxysql"
  network_mode             = "awsvpc"
  requires_compatibilities = ["EC2"]
  cpu                      = var.proxysql_task_cpu
  memory                   = var.proxysql_task_memory
  execution_role_arn       = aws_iam_role.ecs_task_execution.arn
  task_role_arn            = aws_iam_role.proxysql_task.arn

  runtime_platform {
    operating_system_family = "LINUX"
    cpu_architecture        = "X86_64"
  }

  container_definitions = jsonencode([
    {
      name       = "proxysql"
      image      = var.proxysql_image
      essential  = true
      entryPoint = ["/bin/sh", "-ec"]
      command = [<<-EOT
        cat > /tmp/proxysql.cnf <<'CONFIG'
        datadir="/var/lib/proxysql"
        admin_variables =
        {
          admin_credentials="admin:admin"
          mysql_ifaces="127.0.0.1:6032"
        }
        mysql_variables =
        {
          threads=2
          max_connections=1024
          interfaces="0.0.0.0:6033"
        }
        mysql_servers=()
        mysql_users=()
      CONFIG
      cat > /tmp/proxysql-admin.cnf <<'ADMIN'
      [client]
      user=admin
      password=admin
      protocol=tcp
      host=127.0.0.1
      port=6032
      ADMIN
      chmod 0600 /tmp/proxysql-admin.cnf
        exec proxysql -f --initial -c /tmp/proxysql.cnf
      EOT
      ]
      cpu         = var.proxysql_task_cpu - 64
      memory      = var.proxysql_task_memory - 128
      stopTimeout = 30

      healthCheck = {
        command  = ["CMD-SHELL", local.proxysql_healthcheck_command]
        interval = 10
        timeout  = 5
        retries  = 6
        # The bootstrap sidecar can wait up to 120s for the Admin interface and
        # then applies the routing config; allow that before health failures count.
        startPeriod = 180
      }

      portMappings = [
        {
          containerPort = 6033
          protocol      = "tcp"
        }
      ]

      logConfiguration = {
        logDriver = "awslogs"
        options = {
          awslogs-group         = aws_cloudwatch_log_group.proxysql.name
          awslogs-region        = var.aws_region
          awslogs-stream-prefix = "proxysql"
        }
      }
    },
    {
      name       = "proxysql-bootstrap"
      image      = var.proxysql_image
      essential  = false
      entryPoint = ["/bin/sh", "-ec"]
      command    = [local.proxysql_bootstrap_command]
      environment = [
        { name = "PROXYSQL_V1_HOST", value = local.proxysql_v1_mysql_host },
        { name = "PROXYSQL_MIGRATION_HOST", value = local.proxysql_migration_mysql_host },
        { name = "PROXYSQL_MONITOR_USER", value = var.proxysql_monitor_username },
      ]
      secrets = [
        {
          name      = "PROXYSQL_APP_USER"
          valueFrom = "arn:${local.partition}:ssm:${var.aws_region}:${local.account_id}:parameter${var.ssm_parameter_path_prefix}/backend/MYSQL_USER"
        },
        {
          name      = "PROXYSQL_APP_PASSWORD"
          valueFrom = "arn:${local.partition}:ssm:${var.aws_region}:${local.account_id}:parameter${var.ssm_parameter_path_prefix}/backend/MYSQL_PASSWORD"
        },
        {
          name      = "PROXYSQL_MONITOR_PASSWORD"
          valueFrom = local.proxysql_monitor_password_arn
        },
      ]
      dependsOn = [
        {
          containerName = "proxysql"
          condition     = "START"
        }
      ]
      cpu    = 32
      memory = 64

      logConfiguration = {
        logDriver = "awslogs"
        options = {
          awslogs-group         = aws_cloudwatch_log_group.proxysql.name
          awslogs-region        = var.aws_region
          awslogs-stream-prefix = "proxysql-bootstrap"
        }
      }
    },
    {
      name       = "mysql-network-check"
      image      = "public.ecr.aws/docker/library/busybox:1.36"
      essential  = false
      entryPoint = ["/bin/sh", "-c"]
      command    = [local.proxysql_network_check_command]
      dependsOn = [
        {
          containerName = "proxysql"
          condition     = "START"
        }
      ]
      cpu    = 32
      memory = 64

      logConfiguration = {
        logDriver = "awslogs"
        options = {
          awslogs-group         = aws_cloudwatch_log_group.proxysql.name
          awslogs-region        = var.aws_region
          awslogs-stream-prefix = "mysql-network-check"
        }
      }
    },
  ])
}

resource "aws_ecs_service" "proxysql" {
  name                               = "${var.name_prefix}-proxysql"
  cluster                            = aws_ecs_cluster.main.id
  task_definition                    = aws_ecs_task_definition.proxysql.arn
  desired_count                      = 1
  enable_execute_command             = true
  health_check_grace_period_seconds  = 60
  deployment_minimum_healthy_percent = 0
  deployment_maximum_percent         = 100
  wait_for_steady_state              = true

  capacity_provider_strategy {
    capacity_provider = aws_ecs_capacity_provider.service.name
    weight            = 1
    base              = 0
  }

  network_configuration {
    subnets          = local.proxysql_subnet_ids
    security_groups  = [aws_security_group.proxysql_task.id]
    assign_public_ip = false
  }

  service_registries {
    registry_arn = aws_service_discovery_service.proxysql.arn
  }

  deployment_circuit_breaker {
    enable   = true
    rollback = true
  }

  depends_on = [
    aws_vpc_security_group_egress_rule.proxysql_task_https,
    aws_vpc_security_group_ingress_rule.v1_mysql_from_proxysql,
    aws_vpc_security_group_ingress_rule.migration_mysql_from_proxysql,
  ]

  tags = {
    Name = "${var.name_prefix}-proxysql"
  }
}
