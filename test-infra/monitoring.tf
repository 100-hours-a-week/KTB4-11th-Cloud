locals {
  test_system_log_group_name = "/stockspoon/loadtest/system"
  test_system_log_group_arn  = "arn:${data.aws_partition.current.partition}:logs:${var.aws_region}:${data.aws_caller_identity.current.account_id}:log-group:${local.test_system_log_group_name}"
}

resource "aws_cloudwatch_log_group" "test_system" {
  name              = local.test_system_log_group_name
  retention_in_days = 14

  tags = {
    Name        = "${var.name_prefix}-system-logs"
    Project     = "stockspoon"
    Environment = "loadtest"
    ManagedBy   = "Terraform"
  }
}
