variable "aws_region" {
  description = "AWS region for the ECS stack"
  type        = string
  default     = "ap-northeast-2"
}

# Terraform CI 권한이 stockspoon-v2-prod-* 접두사로 제한되어 있으므로 바꾸지 않는다.
variable "name_prefix" {
  description = "Name prefix for production ECS resources (must match the Terraform CI permission scope)"
  type        = string
  default     = "stockspoon-v2-prod"
}

variable "ssm_parameter_path_prefix" {
  description = "SSM Parameter Store path prefix that ECS tasks can read secrets from"
  type        = string
  default     = "/stockspoon/v2/prod"
}

variable "container_log_retention_days" {
  description = "Retention period for ECS container logs"
  type        = number
  default     = 30
}
