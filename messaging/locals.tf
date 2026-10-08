locals {
  name_prefix = "${var.project_name}-v2-${var.environment}"

  common_tags = {
    Project     = var.project_name
    Service     = "messaging"
    Environment = var.environment
    ManagedBy   = "Terraform"
  }
}
