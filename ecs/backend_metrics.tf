variable "telemetry_backend_prometheus_enabled" {
  description = "Scrape backend Actuator metrics using a temporary JWT cookie; disabled until manual rollout"
  type        = bool
  default     = false

  validation {
    condition     = !var.telemetry_backend_prometheus_enabled || var.plg_tempo_enabled
    error_message = "Backend Prometheus scraping requires plg_tempo_enabled=true."
  }
}

locals {
  backend_metrics_cookie_arn = "arn:${local.partition}:ssm:${var.aws_region}:${local.account_id}:parameter${var.ssm_parameter_path_prefix}/telemetry/BACKEND_METRICS_COOKIE"
}

# Alloy uses host networking: grant only ECS host SG access, never public CIDRs.
resource "aws_vpc_security_group_ingress_rule" "backend_metrics_from_alloy" {
  count                        = var.plg_tempo_enabled && var.telemetry_backend_prometheus_enabled ? 1 : 0
  security_group_id            = aws_security_group.backend_task.id
  referenced_security_group_id = aws_security_group.ecs_instance.id
  from_port                    = var.backend_container_port
  to_port                      = var.backend_container_port
  ip_protocol                  = "tcp"
  description                  = "Host Alloy to authenticated backend Actuator endpoint"
}
