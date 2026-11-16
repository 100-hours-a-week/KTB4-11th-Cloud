# Replication Manager supervises the existing two-node MySQL GTID topology.
# Place it outside the database AZ so a single-node FIS stop does not remove
# both the database and its failover controller.

locals {
  repman_database_password_arn    = "arn:${local.partition}:ssm:${var.aws_region}:${local.account_id}:parameter${var.ssm_parameter_path_prefix}/repman/MYSQL_PASSWORD"
  repman_api_password_arn         = "arn:${local.partition}:ssm:${var.aws_region}:${local.account_id}:parameter${var.ssm_parameter_path_prefix}/repman/API_PASSWORD"
  repman_replication_password_arn = "arn:${local.partition}:ssm:${var.aws_region}:${local.account_id}:parameter/stockspoon/v1/db-private-replica/replication-password"
  repman_proxy_dns_name           = local.proxysql_fargate_dns_name
  repman_service_name             = "${var.name_prefix}-repman"

  repman_private_subnet_ids = [
    for subnet_id, subnet in data.aws_subnet.repman_private_candidates : subnet_id
    if subnet.availability_zone != data.aws_instance.repman_primary.availability_zone &&
    subnet.availability_zone != data.aws_instance.repman_replica.availability_zone
  ]

  repman_startup_command = <<-EOT
    set -eu
    : "$REPMAN_DATABASE_PASSWORD"
    : "$REPMAN_REPLICATION_PASSWORD"
    : "$REPMAN_API_PASSWORD"
    : "$REPMAN_PROXYSQL_PASSWORD"

    umask 077
    mkdir -p /var/lib/replication-manager
    cat > /tmp/replication-manager.toml <<CONFIG
    [Default]
    monitoring-datadir = "/var/lib/replication-manager"
    monitoring-save-config = false
    # SSM에서 ECS 작업에 주입한 비밀값을 기준으로 사용한다.
    # EFS의 오래된 secret_store.json 값이 시작 시 주입한 자격 증명을 덮어쓰지 않게 한다.
    monitoring-secret-versioning = false
    http-server = true
    api-port = 10005
    api-https-bind = true
    api-credentials = "admin:$REPMAN_API_PASSWORD"

    [stockspoon]
    title = "StockSpoon MySQL primary-replica"
    prov-orchestrator = "onpremise"
    db-servers-hosts = "${local.proxysql_primary_host}:${var.v1_mysql_port},${local.proxysql_private_replica_host}:${var.v1_mysql_port}"
    db-servers-prefered-master = "${local.proxysql_primary_host}:${var.v1_mysql_port}"
    db-servers-credential = "repman:$REPMAN_DATABASE_PASSWORD"
    replication-credential = "repman_repl:$REPMAN_REPLICATION_PASSWORD"

    failover-mode = "automatic"
    failover-at-sync = true
    failover-max-slave-delay = 0
    failover-limit = 3
    failover-time-limit = 10
    failover-readonly-state = true
    failover-restart-unsafe = false
    check-replication-state = true
    autorejoin = true

    proxysql = true
    proxysql-servers = "${local.repman_proxy_dns_name}"
    proxysql-port = "${var.proxysql_port}"
    proxysql-admin-port = "6032"
    proxysql-user = "admin"
    proxysql-password = "$REPMAN_PROXYSQL_PASSWORD"
    proxysql-writer-hostgroup = 10
    proxysql-reader-hostgroup = 20
    proxysql-bootstrap = true
    proxysql-bootstrap-users = false
    proxysql-bootstrap-hostgroups = true
    proxysql-bootstrap-query-rules = false
    proxysql-bootstrap-variables = false
    CONFIG

    # The Docker image installs its OSC binary at this path.
    exec /usr/bin/replication-manager monitor \
      --config /tmp/replication-manager.toml --http-server
  EOT
}

data "aws_instance" "repman_primary" {
  instance_id = data.terraform_remote_state.app.outputs.db_migration_host.instance_id
}

data "aws_instance" "repman_replica" {
  instance_id = data.terraform_remote_state.app.outputs.db_private_replica_host.instance_id
}

data "aws_subnet" "repman_private_candidates" {
  for_each = toset(data.terraform_remote_state.shared.outputs.private_subnet_ids)
  id       = each.value
}

resource "aws_efs_file_system" "repman" {
  creation_token  = "${var.name_prefix}-repman-state"
  encrypted       = true
  throughput_mode = "bursting"

  tags = {
    Name = "${var.name_prefix}-repman-state"
  }
}

resource "aws_efs_access_point" "repman" {
  file_system_id = aws_efs_file_system.repman.id

  posix_user {
    uid = 10001
    gid = 10001
  }

  root_directory {
    path = "/replication-manager"

    creation_info {
      owner_uid   = 10001
      owner_gid   = 10001
      permissions = "0750"
    }
  }

  tags = {
    Name = "${var.name_prefix}-repman-state"
  }
}

resource "aws_security_group" "repman_task" {
  name        = "${var.name_prefix}-repman-task-sg"
  description = "Replication Manager control plane for the existing MySQL topology"
  vpc_id      = data.terraform_remote_state.shared.outputs.vpc_id

  tags = {
    Name = "${var.name_prefix}-repman-task-sg"
  }
}

resource "aws_security_group" "repman_efs" {
  name        = "${var.name_prefix}-repman-efs-sg"
  description = "NFS access for the Repman persistent state volume"
  vpc_id      = data.terraform_remote_state.shared.outputs.vpc_id

  tags = {
    Name = "${var.name_prefix}-repman-efs-sg"
  }
}

resource "aws_vpc_security_group_ingress_rule" "repman_efs_from_task" {
  security_group_id            = aws_security_group.repman_efs.id
  referenced_security_group_id = aws_security_group.repman_task.id
  from_port                    = 2049
  to_port                      = 2049
  ip_protocol                  = "tcp"
  description                  = "Allow the Repman Fargate task to mount its encrypted EFS state volume"
}

resource "aws_vpc_security_group_egress_rule" "repman_task_to_efs" {
  security_group_id            = aws_security_group.repman_task.id
  referenced_security_group_id = aws_security_group.repman_efs.id
  from_port                    = 2049
  to_port                      = 2049
  ip_protocol                  = "tcp"
  description                  = "Mount the Repman persistent state volume"
}

resource "aws_vpc_security_group_egress_rule" "repman_task_https" {
  security_group_id = aws_security_group.repman_task.id
  cidr_ipv4         = "0.0.0.0/0"
  from_port         = 443
  to_port           = 443
  ip_protocol       = "tcp"
  description       = "Reach AWS control-plane endpoints and pull the Repman image through the private subnet NAT route"
}

resource "aws_vpc_security_group_egress_rule" "repman_task_to_primary_mysql" {
  security_group_id            = aws_security_group.repman_task.id
  referenced_security_group_id = local.proxysql_primary_mysql_sg
  from_port                    = var.v1_mysql_port
  to_port                      = var.v1_mysql_port
  ip_protocol                  = "tcp"
  description                  = "Monitor and manage the current MySQL Primary"
}

resource "aws_vpc_security_group_egress_rule" "repman_task_to_replica_mysql" {
  security_group_id            = aws_security_group.repman_task.id
  referenced_security_group_id = local.proxysql_private_replica_mysql_sg
  from_port                    = var.v1_mysql_port
  to_port                      = var.v1_mysql_port
  ip_protocol                  = "tcp"
  description                  = "Monitor and manage the private MySQL Replica"
}

resource "aws_vpc_security_group_egress_rule" "repman_task_to_proxysql_admin" {
  security_group_id            = aws_security_group.repman_task.id
  referenced_security_group_id = aws_security_group.proxysql_task.id
  from_port                    = 6032
  to_port                      = 6032
  ip_protocol                  = "tcp"
  description                  = "Reconfigure ProxySQL writer and reader hostgroups after promotion"
}

resource "aws_vpc_security_group_ingress_rule" "repman_primary_mysql" {
  security_group_id            = local.proxysql_primary_mysql_sg
  referenced_security_group_id = aws_security_group.repman_task.id
  from_port                    = var.v1_mysql_port
  to_port                      = var.v1_mysql_port
  ip_protocol                  = "tcp"
  description                  = "Allow Repman to monitor and manage the current Primary"
}

resource "aws_vpc_security_group_ingress_rule" "repman_replica_mysql" {
  security_group_id            = local.proxysql_private_replica_mysql_sg
  referenced_security_group_id = aws_security_group.repman_task.id
  from_port                    = var.v1_mysql_port
  to_port                      = var.v1_mysql_port
  ip_protocol                  = "tcp"
  description                  = "Allow Repman to monitor and manage the private Replica"
}

resource "aws_vpc_security_group_ingress_rule" "proxysql_admin_from_repman" {
  count = var.proxysql_fargate_enabled ? 1 : 0

  security_group_id            = aws_security_group.proxysql_task.id
  referenced_security_group_id = aws_security_group.repman_task.id
  from_port                    = 6032
  to_port                      = 6032
  ip_protocol                  = "tcp"
  description                  = "Allow only Repman to update ProxySQL routing during MySQL promotion"
}

resource "aws_vpc_security_group_ingress_rule" "repman_api_from_db_migration" {
  security_group_id            = aws_security_group.repman_task.id
  referenced_security_group_id = data.terraform_remote_state.app.outputs.db_migration_host.security_group_id
  from_port                    = 10005
  to_port                      = 10005
  ip_protocol                  = "tcp"
  description                  = "Private Repman API access from the database operations host"
}

resource "aws_efs_mount_target" "repman" {
  for_each = toset(local.repman_private_subnet_ids)

  file_system_id  = aws_efs_file_system.repman.id
  subnet_id       = each.value
  security_groups = [aws_security_group.repman_efs.id]
}

resource "aws_iam_role" "repman_task" {
  name               = "${var.name_prefix}-repman-task-role"
  assume_role_policy = data.aws_iam_policy_document.ecs_tasks_assume_role.json

  tags = {
    Name = "${var.name_prefix}-repman-task-role"
  }
}

resource "aws_iam_role_policy" "repman_task_efs" {
  name = "${var.name_prefix}-repman-efs-client"
  role = aws_iam_role.repman_task.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = ["elasticfilesystem:ClientMount", "elasticfilesystem:ClientWrite"]
        Resource = aws_efs_file_system.repman.arn
        Condition = {
          StringEquals = {
            "elasticfilesystem:AccessPointArn" = aws_efs_access_point.repman.arn
          }
        }
      },
      {
        Effect = "Allow"
        Action = [
          "ssmmessages:CreateControlChannel",
          "ssmmessages:CreateDataChannel",
          "ssmmessages:OpenControlChannel",
          "ssmmessages:OpenDataChannel",
        ]
        Resource = "*"
      },
    ]
  })
}

resource "aws_iam_role_policy" "repman_execution_secrets" {
  name = "${var.name_prefix}-repman-secrets"
  role = aws_iam_role.ecs_task_execution.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = ["ssm:GetParameters"]
      Resource = [local.repman_replication_password_arn]
    }]
  })
}

resource "aws_cloudwatch_log_group" "repman" {
  name              = "/ecs/${var.name_prefix}/repman"
  retention_in_days = var.container_log_retention_days
}

resource "aws_service_discovery_service" "repman" {
  name = "repman"

  dns_config {
    namespace_id   = aws_service_discovery_private_dns_namespace.proxysql.id
    routing_policy = "MULTIVALUE"

    dns_records {
      ttl  = 10
      type = "A"
    }
  }

  tags = {
    Name = "${var.name_prefix}-repman"
  }
}

resource "aws_ecs_task_definition" "repman" {
  family                   = "${var.name_prefix}-repman"
  network_mode             = "awsvpc"
  requires_compatibilities = ["FARGATE"]
  cpu                      = var.repman_task_cpu
  memory                   = var.repman_task_memory
  execution_role_arn       = aws_iam_role.ecs_task_execution.arn
  task_role_arn            = aws_iam_role.repman_task.arn

  runtime_platform {
    operating_system_family = "LINUX"
    cpu_architecture        = "X86_64"
  }

  volume {
    name = "repman-state"

    efs_volume_configuration {
      file_system_id     = aws_efs_file_system.repman.id
      transit_encryption = "ENABLED"

      authorization_config {
        access_point_id = aws_efs_access_point.repman.id
        iam             = "ENABLED"
      }
    }
  }

  container_definitions = jsonencode([
    {
      name       = "repman"
      image      = var.repman_image
      essential  = true
      user       = "10001:10001"
      entryPoint = ["/bin/sh", "-ec"]
      command    = [local.repman_startup_command]
      environment = [
        { name = "REPMAN_DATABASE_USER", value = "repman" },
        { name = "REPMAN_REPLICATION_USER", value = "repman_repl" },
      ]
      secrets = [
        { name = "REPMAN_DATABASE_PASSWORD", valueFrom = local.repman_database_password_arn },
        { name = "REPMAN_REPLICATION_PASSWORD", valueFrom = local.repman_replication_password_arn },
        { name = "REPMAN_API_PASSWORD", valueFrom = local.repman_api_password_arn },
        { name = "REPMAN_PROXYSQL_PASSWORD", valueFrom = local.proxysql_admin_password_arn },
      ]
      portMappings = [
        {
          containerPort = 10005
          protocol      = "tcp"
        }
      ]
      mountPoints = [
        {
          sourceVolume  = "repman-state"
          containerPath = "/var/lib/replication-manager"
          readOnly      = false
        }
      ]
      logConfiguration = {
        logDriver = "awslogs"
        options = {
          awslogs-group         = aws_cloudwatch_log_group.repman.name
          awslogs-region        = var.aws_region
          awslogs-stream-prefix = "repman"
        }
      }
    }
  ])

  depends_on = [
    aws_iam_role_policy.repman_execution_secrets,
    aws_iam_role_policy.repman_task_efs,
  ]
}

resource "aws_ecs_service" "repman" {
  name                               = local.repman_service_name
  cluster                            = aws_ecs_cluster.main.id
  task_definition                    = aws_ecs_task_definition.repman.arn
  launch_type                        = "FARGATE"
  platform_version                   = "1.4.0"
  desired_count                      = 1
  enable_execute_command             = true
  deployment_minimum_healthy_percent = 0
  deployment_maximum_percent         = 100
  wait_for_steady_state              = true

  network_configuration {
    subnets          = local.repman_private_subnet_ids
    security_groups  = [aws_security_group.repman_task.id]
    assign_public_ip = false
  }

  service_registries {
    registry_arn = aws_service_discovery_service.repman.arn
  }

  deployment_circuit_breaker {
    enable   = true
    rollback = true
  }

  lifecycle {
    precondition {
      condition     = length(local.repman_private_subnet_ids) > 0
      error_message = "Repman must run in a private subnet outside both database AZs."
    }
    precondition {
      condition     = var.repman_task_cpu == 512 && contains([1024, 2048, 3072, 4096], var.repman_task_memory)
      error_message = "Repman Fargate CPU/memory must use 512 CPU with 1024–4096 MiB memory."
    }
  }

  depends_on = [
    aws_efs_mount_target.repman,
    aws_vpc_security_group_egress_rule.repman_task_https,
    aws_vpc_security_group_egress_rule.repman_task_to_efs,
    aws_vpc_security_group_egress_rule.repman_task_to_primary_mysql,
    aws_vpc_security_group_egress_rule.repman_task_to_replica_mysql,
    aws_vpc_security_group_egress_rule.repman_task_to_proxysql_admin,
    aws_vpc_security_group_ingress_rule.repman_primary_mysql,
    aws_vpc_security_group_ingress_rule.repman_replica_mysql,
    aws_vpc_security_group_ingress_rule.proxysql_admin_from_repman,
    aws_vpc_security_group_ingress_rule.repman_api_from_db_migration,
  ]

  tags = {
    Name = local.repman_service_name
  }
}

output "repman" {
  description = "Private Replication Manager endpoint and automatic failover service"
  value = {
    service_name = aws_ecs_service.repman.name
    dns_name     = "repman.${var.proxysql_dns_namespace}"
    api_port     = 10005
    log_group    = aws_cloudwatch_log_group.repman.name
    image        = var.repman_image
  }
}
