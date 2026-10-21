data "aws_caller_identity" "current" {}
data "aws_partition" "current" {}

locals {
  account_id     = data.aws_caller_identity.current.account_id
  partition      = data.aws_partition.current.partition
  telemetry_name = "${var.name_prefix}-telemetry"
  telemetry_files = {
    for name in [
      "compose.yaml", "loki.yaml", "tempo.yaml", "prometheus.yaml",
      "grafana/provisioning/datasources/main.yaml",
    ] : name => file("${path.module}/config/${name}")
  }
}
