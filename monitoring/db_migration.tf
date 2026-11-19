data "aws_security_group" "db_migration_primary" {
  count = var.plg_tempo_enabled ? 1 : 0
  name  = "stockspoon-v1-app-db-migration-sg"
}

data "aws_security_group" "db_private_replica" {
  count = var.plg_tempo_enabled ? 1 : 0
  name  = "stockspoon-v1-db-private-replica-sg"
}

data "aws_security_group" "proxysql_fargate" {
  count = var.plg_tempo_enabled ? 1 : 0
  name  = "stockspoon-v2-prod-proxysql-task-sg"
}

locals {
  telemetry_db_scrape_targets = var.plg_tempo_enabled ? {
    primary_mysql = {
      security_group_id = data.aws_security_group.db_migration_primary[0].id
      port              = 3306
    }
    primary_node = {
      security_group_id = data.aws_security_group.db_migration_primary[0].id
      port              = 9100
    }
    replica_mysql = {
      security_group_id = data.aws_security_group.db_private_replica[0].id
      port              = 3306
    }
    replica_node = {
      security_group_id = data.aws_security_group.db_private_replica[0].id
      port              = 9100
    }
    proxysql_metrics = {
      security_group_id = data.aws_security_group.proxysql_fargate[0].id
      port              = 6070
    }
  } : {}

  telemetry_db_log_sources = var.plg_tempo_enabled ? {
    primary = data.aws_security_group.db_migration_primary[0].id
    replica = data.aws_security_group.db_private_replica[0].id
  } : {}
}

resource "aws_vpc_security_group_egress_rule" "telemetry_db_scrape" {
  for_each = local.telemetry_db_scrape_targets

  security_group_id            = aws_security_group.telemetry[0].id
  referenced_security_group_id = each.value.security_group_id
  from_port                    = each.value.port
  to_port                      = each.value.port
  ip_protocol                  = "tcp"
  description                  = "Central PLG scrape path for ${replace(each.key, "_", " ")}"
}

resource "aws_vpc_security_group_ingress_rule" "telemetry_db_logs" {
  for_each = local.telemetry_db_log_sources

  security_group_id            = aws_security_group.telemetry[0].id
  referenced_security_group_id = each.value
  from_port                    = 3100
  to_port                      = 3100
  ip_protocol                  = "tcp"
  description                  = "DB Alloy log push to central Loki from ${each.key}"
}
