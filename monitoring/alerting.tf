resource "aws_ssm_parameter" "development_discord_webhook" {
  for_each    = var.plg_tempo_enabled ? toset(["app", "ai", "fe", "be"]) : toset([])
  name        = "/stockspoon/monitoring/dev/${each.key}/discord-webhook"
  description = "Development ${each.key} Grafana Discord webhook URL; set the real value in Parameter Store outside Terraform"
  type        = "SecureString"
  tier        = "Standard"

  value_wo         = "UNCONFIGURED"
  value_wo_version = 1
  allowed_pattern  = "^(UNCONFIGURED|https://discord\\.com/api/webhooks/[0-9]+/[A-Za-z0-9_-]+)$"

  tags = {
    Environment = "dev"
    Service     = "grafana-alerting"
    HostRole    = contains(["fe", "be"], each.key) ? "app" : each.key
  }

  # Bootstrap the slot once. Its value and metadata are owned by the operator.
  lifecycle {
    ignore_changes  = all
    prevent_destroy = true
  }
}

output "development_discord_webhook_parameters" {
  description = "Development host and FE/BE SSM SecureString names only; no webhook values"
  value       = { for role, parameter in aws_ssm_parameter.development_discord_webhook : role => parameter.name }
}

resource "aws_ssm_parameter" "production_discord_webhook" {
  for_each    = var.plg_tempo_enabled ? toset(["market-http", "be", "fe", "alb"]) : toset([])
  name        = "/stockspoon/monitoring/prod/${each.key}/discord-webhook"
  description = "Production ${each.key} Grafana Discord webhook URL; set the real value in Parameter Store outside Terraform"
  type        = "SecureString"
  tier        = "Standard"

  value_wo         = "UNCONFIGURED"
  value_wo_version = 1
  allowed_pattern  = "^(UNCONFIGURED|https://discord\\.com/api/webhooks/[0-9]+/[A-Za-z0-9_-]+)$"

  tags = {
    Environment = "prod"
    Service     = "grafana-alerting"
    Component   = each.key
  }

  # Bootstrap the slot once. Its value and metadata are owned by the operator.
  lifecycle {
    ignore_changes  = all
    prevent_destroy = true
  }
}

output "production_discord_webhook_parameters" {
  description = "Production service/ALB webhook parameter names only"
  value       = { for component, parameter in aws_ssm_parameter.production_discord_webhook : component => parameter.name }
}
