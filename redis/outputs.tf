output "target_vpc_id" {
  description = "ID of the test-infra VPC reused by the development Valkey cache"
  value       = data.terraform_remote_state.test.outputs.vpc_id
}

output "valkey_private_subnet_ids" {
  description = "IDs of the test-infra private subnets used by the Valkey serverless cache"
  value       = data.terraform_remote_state.test.outputs.private_subnet_ids
}

output "valkey_security_group_id" {
  description = "ID of the Security Group attached to the Valkey serverless cache"
  value       = aws_security_group.valkey.id
}

output "valkey_cache_name" {
  description = "Name of the development Valkey serverless cache"
  value       = aws_elasticache_serverless_cache.valkey.name
}

output "valkey_cache_arn" {
  description = "ARN of the development Valkey serverless cache"
  value       = aws_elasticache_serverless_cache.valkey.arn
}

output "valkey_endpoint_address" {
  description = "Private endpoint address of the development Valkey serverless cache"
  value       = aws_elasticache_serverless_cache.valkey.endpoint[0].address
}

output "valkey_endpoint_port" {
  description = "TLS port of the development Valkey serverless cache"
  value       = aws_elasticache_serverless_cache.valkey.endpoint[0].port
}

output "backend_valkey_user_name" {
  description = "IAM-enabled ElastiCache user name for the future development Backend"
  value       = aws_elasticache_user.backend.user_name
}

output "backend_valkey_connect_policy_arn" {
  description = "IAM policy ARN to attach to the future development Backend EC2 role"
  value       = aws_iam_policy.backend_connect.arn
}

output "valkey_storage_alarm_name" {
  description = "Name of the Valkey storage usage CloudWatch alarm"
  value       = aws_cloudwatch_metric_alarm.storage_usage_high.alarm_name
}

output "valkey_ecpu_alarm_name" {
  description = "Name of the Valkey ECPU usage CloudWatch alarm"
  value       = aws_cloudwatch_metric_alarm.ecpu_usage_high.alarm_name
}

output "valkey_throttled_commands_alarm_name" {
  description = "Name of the Valkey throttled commands CloudWatch alarm"
  value       = aws_cloudwatch_metric_alarm.throttled_commands.alarm_name
}

output "valkey_discord_notifier_lambda_name" {
  description = "Name of the Lambda that sends Valkey alarm notifications to Discord"
  value       = aws_lambda_function.discord_notifier.function_name
}

output "valkey_discord_webhook_secret_name" {
  description = "Secrets Manager secret where the Valkey Discord webhook URL must be stored outside Terraform"
  value       = aws_secretsmanager_secret.discord_webhook.name
}
