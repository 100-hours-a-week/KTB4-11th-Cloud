variable "telemetry_sse_prometheus_enabled" {
  description = "Enable private SSE scraping after the AI Prometheus image and environment are deployed"
  type        = bool
  default     = false
}

resource "aws_vpc_security_group_ingress_rule" "market_http_metrics_from_alloy" {
  count                        = var.plg_tempo_enabled && local.ai_market_enabled && var.telemetry_sse_prometheus_enabled ? 1 : 0
  security_group_id            = aws_security_group.market_http_task.id
  referenced_security_group_id = aws_security_group.ecs_instance.id
  from_port                    = 9101
  to_port                      = 9101
  ip_protocol                  = "tcp"
  description                  = "ECS host Alloy to private market-http Prometheus listener"
}
