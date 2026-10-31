# The migration host shares the V1 application's VPC and public subnet, while
# retaining its own security group, IAM role, and EC2 resource address.
locals {
  db_migration_tags = {
    Project     = "stockspoon"
    Environment = "v1"
    Purpose     = "db-migration"
    ManagedBy   = "Terraform"
  }
}

resource "aws_security_group" "db_migration" {
  count = var.db_migration_enabled ? 1 : 0

  name        = "stockspoon-v1-app-db-migration-sg"
  description = "MySQL migration target in the existing V1 VPC"
  vpc_id      = data.terraform_remote_state.shared.outputs.vpc_id

  tags = merge(local.db_migration_tags, {
    Name = "stockspoon-v1-app-db-migration-sg"
  })
}

resource "aws_vpc_security_group_ingress_rule" "db_migration_mysql_from_app" {
  count = var.db_migration_enabled ? 1 : 0

  security_group_id            = aws_security_group.db_migration[0].id
  referenced_security_group_id = aws_security_group.app.id
  from_port                    = 3306
  to_port                      = 3306
  ip_protocol                  = "tcp"
  description                  = "V1 backend writes and replication connections to the migration target"
}

resource "aws_vpc_security_group_ingress_rule" "app_mysql_from_db_migration" {
  count = var.db_migration_enabled ? 1 : 0

  security_group_id            = aws_security_group.app.id
  referenced_security_group_id = aws_security_group.db_migration[0].id
  from_port                    = 3306
  to_port                      = 3306
  ip_protocol                  = "tcp"
  description                  = "Seed and replication connections from the migration target to V1 MySQL"
}

resource "aws_vpc_security_group_ingress_rule" "db_migration_ssh" {
  for_each = var.db_migration_enabled ? setunion(var.db_migration_ssh_allowed_cidrs, var.db_migration_admin_cidrs) : toset([])

  security_group_id = aws_security_group.db_migration[0].id
  cidr_ipv4         = each.value
  from_port         = 22
  to_port           = 22
  ip_protocol       = "tcp"
  description       = "Optional key-based SSH access to the migration host"
}

resource "aws_vpc_security_group_egress_rule" "db_migration_outbound" {
  count = var.db_migration_enabled ? 1 : 0

  security_group_id = aws_security_group.db_migration[0].id
  cidr_ipv4         = "0.0.0.0/0"
  from_port         = 443
  to_port           = 443
  ip_protocol       = "tcp"
  description       = "HTTPS for SSM and package downloads"
}

resource "aws_iam_role" "db_migration" {
  count = var.db_migration_enabled ? 1 : 0

  name               = "stockspoon-v1-app-db-migration-role"
  assume_role_policy = data.aws_iam_policy_document.app_cloudwatch_agent_assume_role.json

  tags = merge(local.db_migration_tags, {
    Name = "stockspoon-v1-app-db-migration-role"
  })
}

resource "aws_iam_role_policy_attachment" "db_migration_ssm" {
  count = var.db_migration_enabled ? 1 : 0

  role       = aws_iam_role.db_migration[0].name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

# Keep the switchover control-plane permissions on the database host only.
# The existing migration profile is also used by the load generator and PMM.
resource "aws_iam_role" "db_migration_switchover_runner" {
  count = var.db_migration_enabled ? 1 : 0

  name               = "stockspoon-v1-app-db-migration-runner-role"
  assume_role_policy = data.aws_iam_policy_document.app_cloudwatch_agent_assume_role.json

  tags = merge(local.db_migration_tags, {
    Name = "stockspoon-v1-app-db-migration-runner-role"
  })
}

resource "aws_iam_role_policy_attachment" "db_migration_switchover_runner_ssm" {
  count = var.db_migration_enabled ? 1 : 0

  role       = aws_iam_role.db_migration_switchover_runner[0].name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_role_policy" "db_migration_switchover_runner_monitoring_credentials" {
  count = var.db_migration_enabled ? 1 : 0

  name = "stockspoon-v1-app-db-migration-runner-monitoring"
  role = aws_iam_role.db_migration_switchover_runner[0].id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = ["ssm:GetParameter", "ssm:PutParameter"]
      Resource = "arn:${data.aws_partition.monitoring.partition}:ssm:${var.aws_region}:${data.aws_caller_identity.current.account_id}:parameter/stockspoon/v1/db-migration/mysql-monitoring"
    }]
  })
}

resource "aws_iam_instance_profile" "db_migration_switchover_runner" {
  count = var.db_migration_enabled ? 1 : 0

  name = "stockspoon-v1-app-db-migration-runner-profile"
  role = aws_iam_role.db_migration_switchover_runner[0].name

  tags = merge(local.db_migration_tags, {
    Name = "stockspoon-v1-app-db-migration-runner-profile"
  })
}

data "aws_iam_policy_document" "db_migration_switchover_runner" {
  count = var.db_migration_enabled ? 1 : 0

  statement {
    sid       = "DescribeProductionProxySQLService"
    effect    = "Allow"
    actions   = ["ecs:DescribeServices"]
    resources = ["arn:${data.aws_partition.monitoring.partition}:ecs:${var.aws_region}:${data.aws_caller_identity.current.account_id}:service/stockspoon-v2-prod-cluster/stockspoon-v2-prod-proxysql-fargate"]

    condition {
      test     = "ArnEquals"
      variable = "ecs:cluster"
      values   = ["arn:${data.aws_partition.monitoring.partition}:ecs:${var.aws_region}:${data.aws_caller_identity.current.account_id}:cluster/stockspoon-v2-prod-cluster"]
    }
  }

  statement {
    sid       = "ListProductionProxySQLTasks"
    effect    = "Allow"
    actions   = ["ecs:ListTasks"]
    resources = ["*"]

    condition {
      test     = "ArnEquals"
      variable = "ecs:cluster"
      values   = ["arn:${data.aws_partition.monitoring.partition}:ecs:${var.aws_region}:${data.aws_caller_identity.current.account_id}:cluster/stockspoon-v2-prod-cluster"]
    }
  }

  statement {
    sid       = "DescribeProductionProxySQLTasks"
    effect    = "Allow"
    actions   = ["ecs:DescribeTasks"]
    resources = ["arn:${data.aws_partition.monitoring.partition}:ecs:${var.aws_region}:${data.aws_caller_identity.current.account_id}:task/stockspoon-v2-prod-cluster/*"]

    condition {
      test     = "ArnEquals"
      variable = "ecs:cluster"
      values   = ["arn:${data.aws_partition.monitoring.partition}:ecs:${var.aws_region}:${data.aws_caller_identity.current.account_id}:cluster/stockspoon-v2-prod-cluster"]
    }
  }

  statement {
    sid     = "OpenProxySQLTaskPortForwards"
    effect  = "Allow"
    actions = ["ssm:StartSession"]
    resources = [
      "arn:${data.aws_partition.monitoring.partition}:ecs:${var.aws_region}:${data.aws_caller_identity.current.account_id}:task/stockspoon-v2-prod-cluster/*",
      "arn:${data.aws_partition.monitoring.partition}:ssm:${var.aws_region}::document/AWS-StartPortForwardingSession",
      "arn:${data.aws_partition.monitoring.partition}:ssm:${var.aws_region}:${data.aws_caller_identity.current.account_id}:session/*",
    ]
  }

  statement {
    sid     = "CloseProxySQLPortForwardSessions"
    effect  = "Allow"
    actions = ["ssm:TerminateSession"]
    resources = [
      "arn:${data.aws_partition.monitoring.partition}:ssm:${var.aws_region}:${data.aws_caller_identity.current.account_id}:session/*",
    ]
  }
}

resource "aws_iam_role_policy" "db_migration_switchover_runner" {
  count = var.db_migration_enabled ? 1 : 0

  name   = "stockspoon-v1-app-db-migration-switchover-runner"
  role   = aws_iam_role.db_migration_switchover_runner[0].id
  policy = data.aws_iam_policy_document.db_migration_switchover_runner[0].json
}

resource "aws_iam_instance_profile" "db_migration" {
  count = var.db_migration_enabled ? 1 : 0

  name = "stockspoon-v1-app-db-migration-profile"
  role = aws_iam_role.db_migration[0].name

  tags = merge(local.db_migration_tags, {
    Name = "stockspoon-v1-app-db-migration-profile"
  })
}

resource "aws_instance" "db_migration" {
  count = var.db_migration_enabled ? 1 : 0

  ami                         = data.aws_ssm_parameter.ubuntu_2604_ami.value
  instance_type               = var.db_migration_instance_type
  key_name                    = var.ec2_key_name
  subnet_id                   = data.terraform_remote_state.shared.outputs.public_subnet_id
  associate_public_ip_address = true
  vpc_security_group_ids      = [aws_security_group.db_migration[0].id]
  iam_instance_profile        = aws_iam_instance_profile.db_migration_switchover_runner[0].name

  user_data = templatefile("${path.module}/db-migration/user_data.sh", {
    docker_compose_version = var.docker_compose_version
  })

  root_block_device {
    volume_type           = "gp3"
    volume_size           = var.db_migration_root_volume_size_gib
    encrypted             = true
    delete_on_termination = true

    tags = merge(local.db_migration_tags, {
      Name = "stockspoon-v1-app-db-migration-root"
    })
  }

  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "required"
    http_put_response_hop_limit = 2
  }

  depends_on = [
    aws_iam_role_policy_attachment.db_migration_ssm,
    aws_iam_role_policy_attachment.db_migration_switchover_runner_ssm,
    aws_iam_role_policy.db_migration_switchover_runner,
    aws_iam_role_policy.db_migration_switchover_runner_monitoring_credentials,
    aws_vpc_security_group_egress_rule.db_migration_outbound,
  ]

  lifecycle {
    ignore_changes = [ami]
  }

  tags = merge(local.db_migration_tags, {
    Name = "stockspoon-v1-app-db-migration"
  })
}
