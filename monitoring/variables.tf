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
