# DB migration rehearsal ProxySQL service.
# This first stage starts ProxySQL and tests TCP reachability to MySQL;
# it does not expose a stable endpoint or route Backend writes.

locals {
  proxysql_subnet_ids = [data.terraform_remote_state.shared.outputs.private_subnet_ids[0]]

  proxysql_v1_mysql_host        = data.terraform_remote_state.app.outputs.app_private_ip
  proxysql_migration_mysql_host = try(data.terraform_remote_state.app.outputs.db_migration_host.private_ip, "")
  proxysql_migration_mysql_sg   = try(data.terraform_remote_state.app.outputs.db_migration_host.security_group_id, "")

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
        exec proxysql -f --initial -c /tmp/proxysql.cnf
      EOT
      ]
      cpu         = var.proxysql_task_cpu - 32
      memory      = var.proxysql_task_memory - 64
      stopTimeout = 30

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
  wait_for_steady_state              = false

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
