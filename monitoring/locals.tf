data "aws_caller_identity" "current" {}
data "aws_partition" "current" {}

locals {
  account_id             = data.aws_caller_identity.current.account_id
  partition              = data.aws_partition.current.partition
  telemetry_name         = "${var.name_prefix}-telemetry"
  grafana_public_enabled = var.plg_tempo_enabled && var.grafana_domain_name != ""
  grafana_root_url       = local.grafana_public_enabled ? "https://${var.grafana_domain_name}/" : "http://localhost:13000/"
  telemetry_files = {
    for name in fileset("${path.module}/config", "**") : name => file("${path.module}/config/${name}")
  }
}
