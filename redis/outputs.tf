output "target_vpc_id" {
  description = "ID of the VPC used by the Valkey cache (dev: test-infra, prod: shared-infra)"
  value       = local.vpc_id
}

output "valkey_private_subnet_ids" {
  description = "IDs of the private subnets used by the Valkey serverless cache"
  value       = local.private_subnet_ids
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
  description = "Shared IAM-enabled ElastiCache user name for the development Backend"
  value       = aws_elasticache_user.app["backend"].user_name
}

output "backend_valkey_connect_policy_arn" {
  description = "Shared IAM policy ARN attached to the development Backend EC2 role"
  value       = aws_iam_policy.app_connect["backend"].arn
}

output "ai_valkey_user_name" {
  description = "Shared IAM-enabled ElastiCache user name for the development AI server"
  value       = local.is_dev ? aws_elasticache_user.app["backend"].user_name : null # dev 공용 사용자 전용
}

output "ai_valkey_connect_policy_arn" {
  description = "Shared IAM policy ARN attached to the development AI EC2 role"
  value       = local.is_dev ? aws_iam_policy.app_connect["backend"].arn : null # dev 공용 사용자 전용
}

output "app_valkey_user_name" {
  description = "Shared IAM-enabled ElastiCache user name for development applications"
  value       = local.is_dev ? aws_elasticache_user.app["backend"].user_name : null # dev 공용 사용자 전용
}

output "app_valkey_connect_policy_arn" {
  description = "Shared IAM policy ARN for development applications"
  value       = local.is_dev ? aws_iam_policy.app_connect["backend"].arn : null # dev 공용 사용자 전용
}

output "valkey_user_names" {
  description = "IAM-enabled ElastiCache user name per application service"
  value       = { for service, user in aws_elasticache_user.app : service => user.user_name }
}

output "valkey_connect_policy_arns" {
  description = "Connect policy ARN per application service, attached to that service's role by the compute root"
  value       = { for service, policy in aws_iam_policy.app_connect : service => policy.arn }
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

output "human_valkey_user_names" {
  description = "IAM-enabled ElastiCache user name per developer IAM user"
  value       = { for name, user in aws_elasticache_user.human : name => user.user_name }
}
