data "aws_security_group" "central_db_monitoring" {
  count = var.db_migration_enabled ? 1 : 0

  # Look up the already-managed central PLG SG by its stable production name.
  # This avoids a reverse remote-state edge: monitoring itself reads app-server
  # state for optional ALB routing.
  name = "stockspoon-v2-prod-telemetry"
}

data "aws_instance" "central_db_monitoring" {
  count = var.db_migration_enabled ? 1 : 0

  filter {
    name   = "tag:Name"
    values = ["stockspoon-v2-prod-telemetry"]
  }

  filter {
    name   = "instance-state-name"
    values = ["running"]
  }
}

locals {
  central_db_monitoring_group_id = var.db_migration_enabled ? data.aws_security_group.central_db_monitoring[0].id : null

  central_db_monitoring_ingress = var.db_migration_enabled ? {
    primary_mysql = {
      security_group_id = aws_security_group.db_migration[0].id
      port              = 3306
    }
    primary_node = {
      security_group_id = aws_security_group.db_migration[0].id
      port              = 9100
    }
  } : {}
}

resource "aws_vpc_security_group_ingress_rule" "db_migration_from_central_monitoring" {
  for_each = local.central_db_monitoring_ingress

  security_group_id            = each.value.security_group_id
  referenced_security_group_id = local.central_db_monitoring_group_id
  from_port                    = each.value.port
  to_port                      = each.value.port
  ip_protocol                  = "tcp"
  description                  = "Central PLG scrape of migration DB ${replace(each.key, "_", " ")}"
}

resource "aws_vpc_security_group_ingress_rule" "db_private_replica_from_central_monitoring" {
  for_each = {
    mysql = 3306
    node  = 9100
  }

  security_group_id            = aws_security_group.db_private_replica.id
  referenced_security_group_id = local.central_db_monitoring_group_id
  from_port                    = each.value
  to_port                      = each.value
  ip_protocol                  = "tcp"
  description                  = "Central PLG scrape of private replica ${each.key}"
}

resource "aws_vpc_security_group_egress_rule" "primary_db_to_central_loki" {
  count = var.db_migration_enabled ? 1 : 0

  security_group_id            = aws_security_group.db_migration[0].id
  referenced_security_group_id = local.central_db_monitoring_group_id
  from_port                    = 3100
  to_port                      = 3100
  ip_protocol                  = "tcp"
  description                  = "Migration DB Alloy log push to central Loki"
}

resource "aws_vpc_security_group_egress_rule" "private_replica_to_central_loki" {
  security_group_id            = aws_security_group.db_private_replica.id
  referenced_security_group_id = local.central_db_monitoring_group_id
  from_port                    = 3100
  to_port                      = 3100
  ip_protocol                  = "tcp"
  description                  = "Private replica Alloy log push to central Loki"
}
