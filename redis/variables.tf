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

variable "ai_dev_state_bucket" {
  description = "S3 bucket containing the V2 development AI Terraform state"
  type        = string
  default     = "stockspoon-terraform-state-ai-dev"
}

variable "ai_dev_state_key" {
  description = "S3 key containing the V2 development AI Terraform state"
  type        = string
  default     = "ai-server/dev-infra/terraform.tfstate"
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
