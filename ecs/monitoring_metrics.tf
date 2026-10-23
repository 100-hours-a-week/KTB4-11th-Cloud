resource "aws_vpc_security_group_ingress_rule" "market_http_metrics_from_alloy" {
  count                        = var.plg_tempo_enabled && local.ai_market_enabled ? 1 : 0
  security_group_id            = aws_security_group.market_http_task.id
  referenced_security_group_id = aws_security_group.ecs_instance.id
  from_port                    = 9108
  to_port                      = 9108
  ip_protocol                  = "tcp"
  description                  = "ECS host Alloy to private market-http Prometheus listener"
}
