variable "aws_region" {
  description = "AWS region where the messaging resources are created"
  type        = string
  default     = "ap-northeast-2"
}

variable "environment" {
  description = "Deployment environment"
  type        = string
  default     = "dev"

  validation {
    condition     = contains(["dev", "prod"], var.environment)
    error_message = "environment must be either dev or prod."
  }
}

variable "project_name" {
  description = "Project name used in resource names and tags"
  type        = string
  default     = "stockspoon"

  validation {
    condition     = can(regex("^[a-z0-9-]+$", var.project_name))
    error_message = "project_name must contain only lowercase letters, numbers, and hyphens."
  }
}

variable "proxysql_dns_namespace" {
  description = "Cloud Map private DNS namespace used by the ProxySQL ECS service"
  type        = string
  default     = "stockspoon-v2.internal"
}

variable "proxysql_dns_service_name" {
  description = "Cloud Map service name used by the ProxySQL ECS service"
  type        = string
  default     = "proxysql"
}

variable "proxysql_port" {
  description = "ProxySQL client listener port"
  type        = number
  default     = 6033
}

variable "db_write_replay_database" {
  description = "MySQL schema used by the backend and the DB replay receipt table"
  type        = string
  default     = "stockspoon"
}
