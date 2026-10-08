locals {
  name_prefix = "${var.project_name}-v2-${var.environment}-valkey"

  common_tags = {
    Project     = var.project_name
    Service     = "valkey"
    Environment = var.environment
    ManagedBy   = "Terraform"
  }
}
