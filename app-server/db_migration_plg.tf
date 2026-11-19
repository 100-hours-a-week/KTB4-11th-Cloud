output "db_migration_grafana_url" {
  description = "Central PLG Grafana URL used by DB monitoring"
  value       = var.db_migration_enabled ? var.db_migration_central_grafana_url : null
}
