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

variable "db_write_replay_consumer_enabled" {
  description = "Whether Lambda should consume queued DB writes; keep false until the Backend replay endpoint is ready"
  type        = bool
  default     = false
}

variable "db_write_replay_endpoint_url" {
  description = "HTTPS URL of the authenticated Backend endpoint that replays one DB write envelope"
  type        = string
  default     = ""
}
