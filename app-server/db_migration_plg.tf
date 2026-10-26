resource "aws_vpc_security_group_ingress_rule" "db_migration_grafana_https" {
  for_each = var.db_migration_enabled && var.db_migration_grafana_https_enabled ? setunion(
    var.db_migration_admin_cidrs,
    var.db_migration_pmm_ssh_cidrs,
  ) : toset([])

  security_group_id = aws_security_group.db_migration_support["pmm"].id
  cidr_ipv4         = each.value
  from_port         = 443
  to_port           = 443
  ip_protocol       = "tcp"
  description       = "Grafana HTTPS from the administrator IP only"
}

output "db_migration_grafana_url" {
  description = "Administrator-only Grafana HTTPS URL; configure the proxy with enable_grafana_https.sh"
  value       = var.db_migration_enabled && var.db_migration_grafana_https_enabled ? "https://${aws_instance.db_migration_support["pmm"].public_ip}/" : null
}

resource "aws_vpc_security_group_ingress_rule" "db_migration_loki_from_app" {
  count = var.db_migration_enabled ? 1 : 0

  security_group_id            = aws_security_group.db_migration_support["pmm"].id
  referenced_security_group_id = aws_security_group.app.id
  from_port                    = 3100
  to_port                      = 3100
  ip_protocol                  = "tcp"
  description                  = "V1 Alloy log push to private Loki endpoint"
}

resource "aws_vpc_security_group_ingress_rule" "db_migration_loki_from_db" {
  count = var.db_migration_enabled ? 1 : 0

  security_group_id            = aws_security_group.db_migration_support["pmm"].id
  referenced_security_group_id = aws_security_group.db_migration[0].id
  from_port                    = 3100
  to_port                      = 3100
  ip_protocol                  = "tcp"
  description                  = "Migration DB Alloy log push to private Loki endpoint"
}

resource "aws_vpc_security_group_egress_rule" "db_migration_app_to_loki" {
  count = var.db_migration_enabled ? 1 : 0

  security_group_id            = aws_security_group.app.id
  referenced_security_group_id = aws_security_group.db_migration_support["pmm"].id
  from_port                    = 3100
  to_port                      = 3100
  ip_protocol                  = "tcp"
  description                  = "V1 Alloy log push to private Loki endpoint"
}

resource "aws_vpc_security_group_egress_rule" "db_migration_db_to_loki" {
  count = var.db_migration_enabled ? 1 : 0

  security_group_id            = aws_security_group.db_migration[0].id
  referenced_security_group_id = aws_security_group.db_migration_support["pmm"].id
  from_port                    = 3100
  to_port                      = 3100
  ip_protocol                  = "tcp"
  description                  = "Migration DB Alloy log push to private Loki endpoint"
}

resource "aws_vpc_security_group_ingress_rule" "db_migration_node_exporter_from_pmm" {
  for_each = var.db_migration_enabled ? {
    app = aws_security_group.app.id
    db  = aws_security_group.db_migration[0].id
  } : {}

  security_group_id            = each.value
  referenced_security_group_id = aws_security_group.db_migration_support["pmm"].id
  from_port                    = 9100
  to_port                      = 9100
  ip_protocol                  = "tcp"
  description                  = "Prometheus node exporter scrape from the monitoring host"
}

resource "aws_vpc_security_group_egress_rule" "db_migration_pmm_to_node_exporter" {
  for_each = var.db_migration_enabled ? {
    app = aws_security_group.app.id
    db  = aws_security_group.db_migration[0].id
  } : {}

  security_group_id            = aws_security_group.db_migration_support["pmm"].id
  referenced_security_group_id = each.value
  from_port                    = 9100
  to_port                      = 9100
  ip_protocol                  = "tcp"
  description                  = "Prometheus scrape of rehearsal host metrics"
}
