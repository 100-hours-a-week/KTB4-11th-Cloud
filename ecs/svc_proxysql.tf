# Shared ProxySQL task-definition template and supporting network resources.
# The Fargate service reuses these resources and reapplies routing on each task.

locals {
  proxysql_subnet_ids = [data.terraform_remote_state.shared.outputs.private_subnet_ids[0]]

  # i-081 remains the writer; register the new private GTID replica as reader.
  proxysql_primary_host             = try(data.terraform_remote_state.app.outputs.db_migration_host.private_ip, "")
  proxysql_private_replica_host     = try(data.terraform_remote_state.app.outputs.db_private_replica_host.private_ip, "")
  proxysql_primary_mysql_sg         = try(data.terraform_remote_state.app.outputs.db_migration_host.security_group_id, "")
  proxysql_private_replica_mysql_sg = try(data.terraform_remote_state.app.outputs.db_private_replica_host.security_group_id, "")
  proxysql_pmm_security_group_id    = try(data.terraform_remote_state.app.outputs.db_migration_support_hosts["pmm"].security_group_id, "")
  proxysql_monitor_password_arn     = "arn:${local.partition}:ssm:${var.aws_region}:${local.account_id}:parameter${var.ssm_parameter_path_prefix}/backend/PROXYSQL_MONITOR_PASSWORD"

  # ProxySQL starts with an empty config database, then this sidecar sets the
  # servers, app user, read_only monitoring, and writer/reader hostgroups.
  proxysql_bootstrap_command = <<-EOT
    set -eu

    if [ -z "$PROXYSQL_PRIMARY_HOST" ] || [ -z "$PROXYSQL_PRIVATE_REPLICA_HOST" ]; then
      echo "ERROR: Primary or private replica host is missing from Terraform remote state" >&2
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
    DELETE FROM mysql_servers;
    INSERT INTO mysql_servers (hostgroup_id, hostname, port, comment) VALUES
      (10, '${local.proxysql_primary_host}', ${var.v1_mysql_port}, 'Current GTID Primary'),
      (20, '${local.proxysql_private_replica_host}', ${var.v1_mysql_port}, 'Private GTID replica');

    DELETE FROM mysql_replication_hostgroups
      WHERE writer_hostgroup = 10 OR reader_hostgroup = 20;
    INSERT INTO mysql_replication_hostgroups (writer_hostgroup, reader_hostgroup, check_type, comment)
      VALUES (10, 20, 'read_only', 'Current Primary and private replica');

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

    echo "ProxySQL bootstrap completed for the Primary and private GTID replica"
  EOT

  proxysql_healthcheck_command = "mysql --defaults-extra-file=/tmp/proxysql-admin.cnf -Nse \"SELECT IF((SELECT COUNT(*) FROM runtime_mysql_servers WHERE hostgroup_id = 10 AND hostname = '${local.proxysql_primary_host}' AND status = 'ONLINE') = 1 AND (SELECT COUNT(*) FROM runtime_mysql_servers WHERE hostgroup_id = 20 AND hostname = '${local.proxysql_private_replica_host}' AND status = 'ONLINE') = 1 AND (SELECT COUNT(*) FROM runtime_mysql_replication_hostgroups WHERE writer_hostgroup = 10 AND reader_hostgroup = 20) = 1 AND (SELECT COUNT(DISTINCT username) FROM runtime_mysql_users) >= 1, 1, 0)\" | grep -qx '1'"

  proxysql_network_check_command = join("\n", concat(
    [
      "status=0",
      "if nc -z -w 3 ${local.proxysql_primary_host} ${var.v1_mysql_port}; then",
      "  echo TCP_OK PRIMARY ${local.proxysql_primary_host}:${var.v1_mysql_port}",
      "else",
      "  echo TCP_FAIL PRIMARY ${local.proxysql_primary_host}:${var.v1_mysql_port}",
      "  status=1",
      "fi",
    ],
    local.proxysql_private_replica_host == "" ? [] : [
      "if nc -z -w 3 ${local.proxysql_private_replica_host} ${var.v1_mysql_port}; then",
      "  echo TCP_OK PRIVATE_REPLICA ${local.proxysql_private_replica_host}:${var.v1_mysql_port}",
      "else",
      "  echo TCP_FAIL PRIVATE_REPLICA ${local.proxysql_private_replica_host}:${var.v1_mysql_port}",
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

resource "aws_iam_role" "proxysql_task" {
  name               = "${var.name_prefix}-proxysql-task-role"
  description        = "Task role for ECS Exec into the ProxySQL service task"
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

resource "aws_vpc_security_group_egress_rule" "proxysql_task_https" {
  security_group_id = aws_security_group.proxysql_task.id
  cidr_ipv4         = "0.0.0.0/0"
  from_port         = 443
  to_port           = 443
  ip_protocol       = "tcp"
  description       = "Allow ECS Exec SSM message channels through the existing NAT route"
}

resource "aws_vpc_security_group_egress_rule" "proxysql_task_to_migration_mysql" {
  count = local.proxysql_primary_mysql_sg == "" ? 0 : 1

  security_group_id            = aws_security_group.proxysql_task.id
  referenced_security_group_id = local.proxysql_primary_mysql_sg
  from_port                    = var.v1_mysql_port
  to_port                      = var.v1_mysql_port
  ip_protocol                  = "tcp"
  description                  = "Allow ProxySQL network checks and proxy traffic to the current Primary"
}

resource "aws_vpc_security_group_ingress_rule" "migration_mysql_from_proxysql" {
  count = local.proxysql_primary_mysql_sg == "" ? 0 : 1

  security_group_id            = local.proxysql_primary_mysql_sg
  referenced_security_group_id = aws_security_group.proxysql_task.id
  from_port                    = var.v1_mysql_port
  to_port                      = var.v1_mysql_port
  ip_protocol                  = "tcp"
  description                  = "Allow the ProxySQL ECS task to reach the current Primary"
}

resource "aws_vpc_security_group_egress_rule" "proxysql_task_to_private_replica_mysql" {
  count = local.proxysql_private_replica_mysql_sg == "" ? 0 : 1

  security_group_id            = aws_security_group.proxysql_task.id
  referenced_security_group_id = local.proxysql_private_replica_mysql_sg
  from_port                    = var.v1_mysql_port
  to_port                      = var.v1_mysql_port
  ip_protocol                  = "tcp"
  description                  = "Allow ProxySQL network checks and proxy traffic to the private GTID replica"
}

resource "aws_vpc_security_group_ingress_rule" "private_replica_mysql_from_proxysql" {
  count = local.proxysql_private_replica_mysql_sg == "" ? 0 : 1

  security_group_id            = local.proxysql_private_replica_mysql_sg
  referenced_security_group_id = aws_security_group.proxysql_task.id
  from_port                    = var.v1_mysql_port
  to_port                      = var.v1_mysql_port
  ip_protocol                  = "tcp"
  description                  = "Allow the ProxySQL ECS task to reach the private GTID replica"
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
        { name = "PROXYSQL_PRIMARY_HOST", value = local.proxysql_primary_host },
        { name = "PROXYSQL_PRIVATE_REPLICA_HOST", value = local.proxysql_private_replica_host },
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
