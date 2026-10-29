variable "telemetry_backend_prometheus_enabled" {
  description = "Scrape backend Actuator Prometheus metrics from host-local Alloy without authentication"
  type        = bool
  default     = false

  validation {
    condition     = !var.telemetry_backend_prometheus_enabled || var.plg_tempo_enabled
    error_message = "Backend Prometheus scraping requires plg_tempo_enabled=true."
  }
}

variable "backend_actuator_block_rule_priority" {
  description = "Priority of the public HTTPS listener rule that blocks backend Actuator metrics paths"
  type        = number
  default     = 50

  validation {
    condition = (
      var.backend_actuator_block_rule_priority >= 1 &&
      floor(var.backend_actuator_block_rule_priority) == var.backend_actuator_block_rule_priority &&
      var.backend_actuator_block_rule_priority < var.backend_canary_rule_priority &&
      var.backend_actuator_block_rule_priority < var.market_http_rule_priority
    )
    error_message = "Actuator block priority must be an integer evaluated before the API and market-http rules."
  }
}

# Alloy uses host networking: grant only ECS host SG access, never public CIDRs.
resource "aws_vpc_security_group_ingress_rule" "backend_metrics_from_alloy" {
  count                        = var.plg_tempo_enabled && var.telemetry_backend_prometheus_enabled ? 1 : 0
  security_group_id            = aws_security_group.backend_task.id
  referenced_security_group_id = aws_security_group.ecs_instance.id
  from_port                    = var.backend_container_port
  to_port                      = var.backend_container_port
  ip_protocol                  = "tcp"
  description                  = "Host Alloy to unauthenticated backend Actuator endpoint"
}

# GET /actuator/prometheus is unauthenticated in the BE. The public listener only
# routes /api/* to the backend today; this rule keeps metrics bodies off the
# internet even if routing changes. ALB target health checks bypass listener rules.
resource "aws_lb_listener_rule" "backend_actuator_block" {
  listener_arn = data.terraform_remote_state.app.outputs.https_listener_arn
  priority     = var.backend_actuator_block_rule_priority

  action {
    type = "fixed-response"

    fixed_response {
      content_type = "text/plain"
      message_body = "Not Found"
      status_code  = "404"
    }
  }

  condition {
    path_pattern {
      values = ["/actuator/prometheus", "/actuator/prometheus/*", "/actuator/metrics", "/actuator/metrics/*"]
    }
  }

  tags = {
    Name = "${var.name_prefix}-backend-actuator-block"
  }
}
