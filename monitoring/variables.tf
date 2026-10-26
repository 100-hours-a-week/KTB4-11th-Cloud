variable "plg_tempo_enabled" {
  description = "Create the independent V2 PLG/Tempo monitoring server"
  type        = bool
  default     = false
}

variable "plg_tempo_instance_type" {
  description = "Initial single-server size; x86_64 Amazon Linux 2023"
  type        = string
  default     = "t3.xlarge"
}

variable "plg_tempo_data_size_gib" {
  description = "Persistent gp3 disk for Prometheus, Grafana and Loki/Tempo WAL/cache"
  type        = number
  default     = 100

  validation {
    condition     = var.plg_tempo_data_size_gib >= 30
    error_message = "The data disk must be at least 30 GiB."
  }
}

variable "aws_region" {
  description = "AWS region for the independent monitoring stack"
  type        = string
  default     = "ap-northeast-2"
}

variable "name_prefix" {
  description = "Resource prefix; the monitoring server adds -telemetry"
  type        = string
  default     = "stockspoon-v2-prod"
}

variable "grafana_domain_name" {
  description = "Optional public Grafana hostname, e.g. monitoring.stock-spoon.com; empty keeps SSM-only access"
  type        = string
  default     = ""

  validation {
    condition     = var.grafana_domain_name == "" || can(regex("^[a-z0-9]([a-z0-9.-]*[a-z0-9])?\\.[a-z]{2,}$", var.grafana_domain_name))
    error_message = "Use a lowercase DNS hostname without a scheme, port or trailing dot."
  }
}

variable "grafana_route53_zone_name" {
  description = "Existing public Route 53 hosted zone containing the Grafana hostname"
  type        = string
  default     = "stock-spoon.com"
}

variable "grafana_listener_rule_priority" {
  description = "Host rule priority on the existing HTTPS listener; precedes API path rules at 100/200"
  type        = number
  default     = 10

  validation {
    condition     = var.grafana_listener_rule_priority >= 1 && var.grafana_listener_rule_priority < 100 && floor(var.grafana_listener_rule_priority) == var.grafana_listener_rule_priority
    error_message = "Choose an unused integer priority from 1 to 99, before the application path rules."
  }
}
