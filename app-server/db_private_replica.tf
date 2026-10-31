locals {
  db_private_replica_tags = {
    Project     = "stockspoon"
    Environment = "v1"
    Purpose     = "private-db-replica"
    ManagedBy   = "Terraform"
  }

  db_private_replica_root_password_parameter = "/stockspoon/v1/db-private-replica/root-password"
  db_private_replica_repl_password_parameter = "/stockspoon/v1/db-private-replica/replication-password"
  db_private_replica_subnet_ids = sort([
    for subnet_id, subnet in data.aws_subnet.db_private_replica_candidates :
    subnet_id if subnet.availability_zone == aws_instance.db_migration[0].availability_zone
  ])
  db_private_replica_subnet_id = local.db_private_replica_subnet_ids[0]
}

data "aws_subnet" "db_private_replica_candidates" {
  for_each = toset(data.terraform_remote_state.shared.outputs.private_subnet_ids)

  id = each.value
}

resource "aws_security_group" "db_private_replica" {
  name        = "stockspoon-v1-db-private-replica-sg"
  description = "Private MySQL replica; only ProxySQL and the source DB can reach MySQL"
  vpc_id      = data.terraform_remote_state.shared.outputs.vpc_id

  tags = merge(local.db_private_replica_tags, {
    Name = "stockspoon-v1-db-private-replica-sg"
  })
}

resource "aws_vpc_security_group_egress_rule" "db_private_replica_https" {
  security_group_id = aws_security_group.db_private_replica.id
  cidr_ipv4         = "0.0.0.0/0"
  from_port         = 443
  to_port           = 443
  ip_protocol       = "tcp"
  description       = "SSM and secure parameter retrieval through the private subnet NAT route"
}

resource "aws_vpc_security_group_egress_rule" "db_private_replica_http" {
  security_group_id = aws_security_group.db_private_replica.id
  cidr_ipv4         = "0.0.0.0/0"
  from_port         = 80
  to_port           = 80
  ip_protocol       = "tcp"
  description       = "Ubuntu package installation through the private subnet NAT route"
}

resource "aws_vpc_security_group_egress_rule" "db_private_replica_to_primary" {
  security_group_id            = aws_security_group.db_private_replica.id
  referenced_security_group_id = aws_security_group.db_migration[0].id
  from_port                    = 3306
  to_port                      = 3306
  ip_protocol                  = "tcp"
  description                  = "GTID auto-position replication from the current Primary"
}

resource "aws_vpc_security_group_ingress_rule" "primary_mysql_from_private_replica" {
  security_group_id            = aws_security_group.db_migration[0].id
  referenced_security_group_id = aws_security_group.db_private_replica.id
  from_port                    = 3306
  to_port                      = 3306
  ip_protocol                  = "tcp"
  description                  = "Allow the private GTID replica to connect to the current Primary"
}

resource "aws_iam_role" "db_private_replica" {
  name               = "stockspoon-v1-db-private-replica-role"
  assume_role_policy = data.aws_iam_policy_document.app_cloudwatch_agent_assume_role.json

  tags = merge(local.db_private_replica_tags, {
    Name = "stockspoon-v1-db-private-replica-role"
  })
}

resource "aws_iam_role_policy_attachment" "db_private_replica_ssm" {
  role       = aws_iam_role.db_private_replica.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_role_policy" "db_private_replica_parameters" {
  name = "stockspoon-v1-db-private-replica-parameters"
  role = aws_iam_role.db_private_replica.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Action = ["ssm:GetParameter"]
      Resource = [
        "arn:${data.aws_partition.monitoring.partition}:ssm:${var.aws_region}:${data.aws_caller_identity.current.account_id}:parameter${local.db_private_replica_root_password_parameter}",
        "arn:${data.aws_partition.monitoring.partition}:ssm:${var.aws_region}:${data.aws_caller_identity.current.account_id}:parameter${local.db_private_replica_repl_password_parameter}",
        "arn:${data.aws_partition.monitoring.partition}:ssm:${var.aws_region}:${data.aws_caller_identity.current.account_id}:parameter/stockspoon/v2/prod/backend/PROXYSQL_MONITOR_PASSWORD",
      ]
    }]
  })
}

resource "aws_iam_instance_profile" "db_private_replica" {
  name = "stockspoon-v1-db-private-replica-profile"
  role = aws_iam_role.db_private_replica.name

  tags = merge(local.db_private_replica_tags, {
    Name = "stockspoon-v1-db-private-replica-profile"
  })
}

# The current Primary needs the replica-only SecureString and the ProxySQL
# monitor password so it can prepare narrowly scoped MySQL accounts without
# exposing credentials in SSM command arguments or Terraform state.
resource "aws_iam_role_policy" "db_migration_replication_password" {
  count = var.db_migration_enabled ? 1 : 0

  name = "stockspoon-v1-db-migration-replication-password"
  role = aws_iam_role.db_migration_switchover_runner[0].id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Action = ["ssm:GetParameter"]
      Resource = [
        "arn:${data.aws_partition.monitoring.partition}:ssm:${var.aws_region}:${data.aws_caller_identity.current.account_id}:parameter${local.db_private_replica_repl_password_parameter}",
        "arn:${data.aws_partition.monitoring.partition}:ssm:${var.aws_region}:${data.aws_caller_identity.current.account_id}:parameter/stockspoon/v2/prod/backend/PROXYSQL_MONITOR_PASSWORD",
      ]
    }]
  })
}

resource "aws_instance" "db_private_replica" {
  ami                         = data.aws_ssm_parameter.ubuntu_2604_ami.value
  instance_type               = var.db_migration_instance_type
  subnet_id                   = local.db_private_replica_subnet_id
  associate_public_ip_address = false
  vpc_security_group_ids      = [aws_security_group.db_private_replica.id]
  iam_instance_profile        = aws_iam_instance_profile.db_private_replica.name

  user_data = templatefile("${path.module}/db-private-replica/user_data.sh", {
    aws_region              = var.aws_region
    docker_compose_version  = var.docker_compose_version
    mysql_compose           = file("${path.module}/db-private-replica/mysql-compose.yaml")
    root_password_parameter = local.db_private_replica_root_password_parameter
  })

  root_block_device {
    volume_type           = "gp3"
    volume_size           = var.db_migration_root_volume_size_gib
    encrypted             = true
    delete_on_termination = true

    tags = merge(local.db_private_replica_tags, {
      Name = "stockspoon-v1-db-private-replica-root"
    })
  }

  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "required"
    http_put_response_hop_limit = 1
  }

  depends_on = [
    aws_iam_role_policy_attachment.db_private_replica_ssm,
    aws_iam_role_policy.db_private_replica_parameters,
  ]

  tags = merge(local.db_private_replica_tags, {
    Name = "stockspoon-v1-db-private-replica"
  })
}

# The main-branch deployment job sends narrowly scoped SSM Run Command requests
# to the existing Primary and this replica to initialize and verify GTID sync.
resource "aws_iam_role_policy" "github_actions_db_private_replica_bootstrap" {
  count = var.db_migration_enabled ? 1 : 0

  name = "stockspoon-v1-github-actions-db-private-replica-bootstrap"
  role = aws_iam_role.github_actions_terraform_apply.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = ["ssm:SendCommand"]
        Resource = [
          "arn:${data.aws_partition.monitoring.partition}:ec2:${var.aws_region}:${data.aws_caller_identity.current.account_id}:instance/*",
        ]
        Condition = {
          StringEquals = {
            "ssm:resourceTag/Project" = "stockspoon"
            "ssm:resourceTag/Purpose" = ["db-migration", "private-db-replica"]
          }
        }
      },
      {
        Effect   = "Allow"
        Action   = ["ssm:SendCommand"]
        Resource = "arn:${data.aws_partition.monitoring.partition}:ssm:${var.aws_region}::document/AWS-RunShellScript"
      },
      {
        Effect = "Allow"
        Action = [
          "ssm:DescribeInstanceInformation",
          "ssm:GetCommandInvocation",
          "ssm:ListCommands",
        ]
        Resource = "*"
      },
    ]
  })
}

# Stream a consistent source baseline into the empty private replica, record its
# GTID set, and verify GTID auto-position replication. Keeping this bootstrap
# here makes the dependency explicit: ecs is applied only after replication
# threads start successfully.
resource "terraform_data" "db_private_replica_bootstrap" {
  input = {
    primary_instance_id = aws_instance.db_migration[0].id
    replica_instance_id = aws_instance.db_private_replica.id
  }

  triggers_replace = [
    aws_instance.db_migration[0].id,
    aws_instance.db_migration[0].private_ip,
    aws_instance.db_private_replica.id,
    aws_instance.db_private_replica.private_ip,
    filesha256("${path.module}/db-private-replica/bootstrap_replica.sh"),
    filesha256("${path.module}/db-private-replica/bootstrap_cd.py"),
  ]

  provisioner "local-exec" {
    command     = "python3 db-private-replica/bootstrap_cd.py"
    working_dir = path.module

    environment = {
      AWS_REGION                     = var.aws_region
      DB_PRIMARY_INSTANCE_ID         = aws_instance.db_migration[0].id
      DB_PRIMARY_PRIVATE_IP          = aws_instance.db_migration[0].private_ip
      DB_PRIVATE_REPLICA_INSTANCE_ID = aws_instance.db_private_replica.id
      DB_PRIVATE_REPLICA_PRIVATE_IP  = aws_instance.db_private_replica.private_ip
    }
  }

  depends_on = [
    aws_iam_role_policy.github_actions_db_private_replica_bootstrap,
    aws_iam_role_policy.db_migration_replication_password,
    aws_vpc_security_group_egress_rule.db_private_replica_to_primary,
    aws_vpc_security_group_ingress_rule.primary_mysql_from_private_replica,
  ]
}
