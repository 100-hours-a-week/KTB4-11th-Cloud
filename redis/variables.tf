variable "aws_region" {
  description = "AWS region where the Valkey resources are created"
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

variable "test_infra_state_bucket" {
  description = "S3 bucket containing the test-infra Terraform state"
  type        = string
  default     = "stockspoon-terraform-state-v1"
}

variable "test_infra_state_key" {
  description = "S3 key containing the test-infra Terraform state"
  type        = string
  default     = "test-infra/terraform.tfstate"
}

variable "valkey_port" {
  description = "TLS port used by the Valkey serverless cache"
  type        = number
  default     = 6379

  validation {
    condition     = var.valkey_port >= 1 && var.valkey_port <= 65535
    error_message = "valkey_port must be between 1 and 65535."
  }
}

variable "valkey_major_engine_version" {
  description = "Major Valkey engine version used by the serverless cache"
  type        = string
  default     = "8"

  validation {
    condition     = contains(["7", "8", "9"], var.valkey_major_engine_version)
    error_message = "valkey_major_engine_version must be a supported major version: 7, 8, or 9."
  }
}

variable "valkey_max_data_storage_gb" {
  description = "Maximum data storage allowed for the development serverless cache in GB"
  type        = number
  default     = 1

  validation {
    condition     = var.valkey_max_data_storage_gb >= 1
    error_message = "valkey_max_data_storage_gb must be at least 1 GB."
  }
}

variable "valkey_max_ecpu_per_second" {
  description = "Maximum ECPU allowed per second for the development serverless cache"
  type        = number
  default     = 1000

  validation {
    condition     = var.valkey_max_ecpu_per_second >= 1000
    error_message = "valkey_max_ecpu_per_second must be at least 1000."
  }
}

variable "discord_webhook_secret_name" {
  description = "Existing Secrets Manager secret containing the Discord webhook URL"
  type        = string
  default     = "stockspoon/v2/dev/sqs/discord-webhook"
}
