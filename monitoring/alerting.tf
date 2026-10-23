resource "aws_ssm_parameter" "development_discord_webhook" {
  count       = var.plg_tempo_enabled ? 1 : 0
  name        = "/stockspoon/monitoring/dev/discord-webhook"
  description = "Development Grafana Discord webhook URL; set the real value in Parameter Store outside Terraform"
  type        = "SecureString"
  tier        = "Standard"

  value_wo         = "UNCONFIGURED"
  value_wo_version = 1
  allowed_pattern  = "^(UNCONFIGURED|https://discord\\.com/api/webhooks/[0-9]+/[A-Za-z0-9_-]+)$"

  tags = {
    Environment = "dev"
    Service     = "grafana-alerting"
  }

  # Bootstrap the slot once. Its value and metadata are owned by the operator.
  lifecycle {
    ignore_changes  = all
    prevent_destroy = true
  }
}

output "development_discord_webhook_parameter" {
  description = "SSM SecureString name only; the webhook value is never an output"
  value       = var.plg_tempo_enabled ? aws_ssm_parameter.development_discord_webhook[0].name : null
}
