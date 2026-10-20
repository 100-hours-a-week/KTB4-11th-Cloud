locals {
  db_migration_support_hosts = var.db_migration_enabled ? {
    loadgen = {
      instance_type   = var.db_migration_loadgen_instance_type
      volume_size_gib = 20
    }
    pmm = {
      instance_type   = var.db_migration_pmm_instance_type
      volume_size_gib = 60
    }
  } : {}

  db_migration_support_admin_rules = merge(
    {
      for entry in setproduct(keys(local.db_migration_support_hosts), var.db_migration_admin_cidrs) :
      "${entry[0]}:${entry[1]}" => {
        host = entry[0]
        cidr = entry[1]
      }
    },
    {
      for cidr in var.db_migration_pmm_ssh_cidrs :
      "pmm:${cidr}" => {
        host = "pmm"
        cidr = cidr
      }
    }
  )

  db_migration_support_web_egress = {
    for entry in setproduct(keys(local.db_migration_support_hosts), [80, 443]) :
    "${entry[0]}:${entry[1]}" => {
      host = entry[0]
      port = entry[1]
    }
  }
}

resource "aws_iam_role_policy" "db_migration_monitoring_credentials" {
  count = var.db_migration_enabled ? 1 : 0

  name = "stockspoon-v1-app-db-migration-monitoring"
  role = aws_iam_role.db_migration[0].id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = ["ssm:GetParameter", "ssm:PutParameter"]
      Resource = "arn:${data.aws_partition.monitoring.partition}:ssm:${var.aws_region}:${data.aws_caller_identity.monitoring.account_id}:parameter/stockspoon/v1/db-migration/mysql-monitoring"
    }]
  })
}

resource "aws_security_group" "db_migration_support" {
  for_each = local.db_migration_support_hosts

  name        = "stockspoon-v1-app-db-migration-${each.key}-sg"
  description = "Database rehearsal ${each.key} host"
  vpc_id      = data.terraform_remote_state.shared.outputs.vpc_id

  tags = merge(local.db_migration_tags, {
    Name = "stockspoon-v1-app-db-migration-${each.key}-sg"
  })
}

resource "aws_vpc_security_group_ingress_rule" "db_migration_support_ssh" {
  for_each = local.db_migration_support_admin_rules

  security_group_id = aws_security_group.db_migration_support[each.value.host].id
  cidr_ipv4         = each.value.cidr
  from_port         = 22
  to_port           = 22
  ip_protocol       = "tcp"
  description       = "SSH from the administrator IP only"
}

resource "aws_vpc_security_group_ingress_rule" "db_migration_pmm_admin" {
  for_each = var.db_migration_enabled ? var.db_migration_admin_cidrs : toset([])

  security_group_id = aws_security_group.db_migration_support["pmm"].id
  cidr_ipv4         = each.value
  from_port         = 8443
  to_port           = 8443
  ip_protocol       = "tcp"
  description       = "PMM HTTPS UI from the administrator IP only"
}

resource "aws_vpc_security_group_ingress_rule" "db_migration_pmm_from_app" {
  count = var.db_migration_enabled ? 1 : 0

  security_group_id            = aws_security_group.db_migration_support["pmm"].id
  referenced_security_group_id = aws_security_group.app.id
  from_port                    = 8443
  to_port                      = 8443
  ip_protocol                  = "tcp"
  description                  = "PMM agent connection from the V1 application host"
}

resource "aws_vpc_security_group_ingress_rule" "db_migration_pmm_from_db" {
  count = var.db_migration_enabled ? 1 : 0

  security_group_id            = aws_security_group.db_migration_support["pmm"].id
  referenced_security_group_id = aws_security_group.db_migration[0].id
  from_port                    = 8443
  to_port                      = 8443
  ip_protocol                  = "tcp"
  description                  = "PMM agent connection from the migration database host"
}

resource "aws_vpc_security_group_ingress_rule" "db_migration_pmm_from_loadgen" {
  count = var.db_migration_enabled ? 1 : 0

  security_group_id            = aws_security_group.db_migration_support["pmm"].id
  referenced_security_group_id = aws_security_group.db_migration_support["loadgen"].id
  from_port                    = 8443
  to_port                      = 8443
  ip_protocol                  = "tcp"
  description                  = "PMM agent connection from the load generator"
}

resource "aws_vpc_security_group_ingress_rule" "db_migration_mysql_from_pmm" {
  count = var.db_migration_enabled ? 1 : 0

  security_group_id            = aws_security_group.db_migration[0].id
  referenced_security_group_id = aws_security_group.db_migration_support["pmm"].id
  from_port                    = 3306
  to_port                      = 3306
  ip_protocol                  = "tcp"
  description                  = "Read-only MySQL monitoring from the PMM server"
}

resource "aws_vpc_security_group_ingress_rule" "app_mysql_from_migration_pmm" {
  count = var.db_migration_enabled ? 1 : 0

  security_group_id            = aws_security_group.app.id
  referenced_security_group_id = aws_security_group.db_migration_support["pmm"].id
  from_port                    = 3306
  to_port                      = 3306
  ip_protocol                  = "tcp"
  description                  = "Read-only MySQL monitoring from the PMM server when the private port is published"
}

resource "aws_vpc_security_group_ingress_rule" "app_http_from_migration_loadgen" {
  for_each = var.db_migration_enabled ? toset(["80", "443"]) : toset([])

  security_group_id            = aws_security_group.app.id
  referenced_security_group_id = aws_security_group.db_migration_support["loadgen"].id
  from_port                    = tonumber(each.value)
  to_port                      = tonumber(each.value)
  ip_protocol                  = "tcp"
  description                  = "API traffic from the dedicated rehearsal load generator"
}

resource "aws_vpc_security_group_egress_rule" "db_migration_support_web" {
  for_each = local.db_migration_support_web_egress

  security_group_id = aws_security_group.db_migration_support[each.value.host].id
  cidr_ipv4         = "0.0.0.0/0"
  from_port         = each.value.port
  to_port           = each.value.port
  ip_protocol       = "tcp"
  description       = "HTTP and HTTPS for packages, SSM, and API traffic"
}

resource "aws_vpc_security_group_egress_rule" "db_migration_http" {
  count = var.db_migration_enabled ? 1 : 0

  security_group_id = aws_security_group.db_migration[0].id
  cidr_ipv4         = "0.0.0.0/0"
  from_port         = 80
  to_port           = 80
  ip_protocol       = "tcp"
  description       = "HTTP package repository downloads"
}

resource "aws_vpc_security_group_egress_rule" "db_migration_to_source_mysql" {
  count = var.db_migration_enabled ? 1 : 0

  security_group_id            = aws_security_group.db_migration[0].id
  referenced_security_group_id = aws_security_group.app.id
  from_port                    = 3306
  to_port                      = 3306
  ip_protocol                  = "tcp"
  description                  = "Seed and replication connection to V1 MySQL"
}

resource "aws_vpc_security_group_egress_rule" "db_migration_to_pmm" {
  count = var.db_migration_enabled ? 1 : 0

  security_group_id            = aws_security_group.db_migration[0].id
  referenced_security_group_id = aws_security_group.db_migration_support["pmm"].id
  from_port                    = 8443
  to_port                      = 8443
  ip_protocol                  = "tcp"
  description                  = "PMM agent HTTPS connection"
}

resource "aws_vpc_security_group_egress_rule" "db_migration_loadgen_to_pmm" {
  count = var.db_migration_enabled ? 1 : 0

  security_group_id            = aws_security_group.db_migration_support["loadgen"].id
  referenced_security_group_id = aws_security_group.db_migration_support["pmm"].id
  from_port                    = 8443
  to_port                      = 8443
  ip_protocol                  = "tcp"
  description                  = "PMM agent HTTPS connection"
}

resource "aws_vpc_security_group_egress_rule" "db_migration_pmm_to_target_mysql" {
  count = var.db_migration_enabled ? 1 : 0

  security_group_id            = aws_security_group.db_migration_support["pmm"].id
  referenced_security_group_id = aws_security_group.db_migration[0].id
  from_port                    = 3306
  to_port                      = 3306
  ip_protocol                  = "tcp"
  description                  = "Read-only monitoring of the migration MySQL server"
}

resource "aws_vpc_security_group_egress_rule" "db_migration_pmm_to_source_mysql" {
  count = var.db_migration_enabled ? 1 : 0

  security_group_id            = aws_security_group.db_migration_support["pmm"].id
  referenced_security_group_id = aws_security_group.app.id
  from_port                    = 3306
  to_port                      = 3306
  ip_protocol                  = "tcp"
  description                  = "Read-only monitoring of V1 MySQL when its private port is published"
}

resource "aws_instance" "db_migration_support" {
  for_each = local.db_migration_support_hosts

  ami                         = data.aws_ssm_parameter.ubuntu_2604_ami.value
  instance_type               = each.value.instance_type
  key_name                    = var.ec2_key_name
  subnet_id                   = data.terraform_remote_state.shared.outputs.public_subnet_id
  associate_public_ip_address = true
  vpc_security_group_ids      = [aws_security_group.db_migration_support[each.key].id]
  iam_instance_profile        = aws_iam_instance_profile.db_migration[0].name

  user_data = templatefile("${path.module}/db-migration/support_user_data.sh", {
    role                   = each.key
    docker_compose_version = var.docker_compose_version
    pmm_compose            = file("${path.module}/db-migration/pmm-compose.yaml")
  })

  root_block_device {
    volume_type           = "gp3"
    volume_size           = each.value.volume_size_gib
    encrypted             = true
    delete_on_termination = true

    tags = merge(local.db_migration_tags, {
      Name = "stockspoon-v1-app-db-migration-${each.key}-root"
    })
  }

  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "required"
    http_put_response_hop_limit = 2
  }

  depends_on = [
    aws_iam_role_policy_attachment.db_migration_ssm,
    aws_vpc_security_group_egress_rule.db_migration_support_web,
  ]

  lifecycle {
    ignore_changes = [ami]
  }

  tags = merge(local.db_migration_tags, {
    Name = "stockspoon-v1-app-db-migration-${each.key}"
  })
}
