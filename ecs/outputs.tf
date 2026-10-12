output "ecs_instance_profile_name" {
  description = "Instance profile for ECS container instances (used by the launch template)"
  value       = aws_iam_instance_profile.ecs_instance.name
}

output "ecs_instance_role_arn" {
  description = "IAM role ARN for ECS container instances"
  value       = aws_iam_role.ecs_instance.arn
}

output "ecs_task_execution_role_arn" {
  description = "IAM role ARN used by the ECS agent to start tasks"
  value       = aws_iam_role.ecs_task_execution.arn
}

output "backend_task_role_arn" {
  description = "IAM role ARN assumed by backend application containers"
  value       = aws_iam_role.backend_task.arn
}

output "backend_log_group_name" {
  description = "CloudWatch Logs group for backend containers"
  value       = aws_cloudwatch_log_group.backend.name
}
