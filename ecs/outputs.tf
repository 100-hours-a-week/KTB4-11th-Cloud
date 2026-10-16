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

output "cluster_name" {
  description = "ECS cluster name"
  value       = aws_ecs_cluster.main.name
}

output "service_asg_name" {
  description = "Auto Scaling group for the service capacity provider"
  value       = aws_autoscaling_group.service.name
}

output "service_capacity_provider_name" {
  description = "Capacity provider for Backend and Socket services"
  value       = aws_ecs_capacity_provider.service.name
}

output "backend_service_name" {
  description = "Backend ECS service name"
  value       = aws_ecs_service.backend.name
}

output "backend_green_target_group_arn" {
  description = "Green target group for the ECS backend (used for canary weights)"
  value       = aws_lb_target_group.backend_green.arn
}

output "backend_task_security_group_id" {
  description = "Security group attached to backend task ENIs"
  value       = aws_security_group.backend_task.id
}

output "proxysql_service_name" {
  description = "Standalone ProxySQL ECS service used for the database migration rehearsal"
  value       = aws_ecs_service.proxysql.name
}

output "proxysql_log_group_name" {
  description = "CloudWatch Logs group for ProxySQL and its one-shot MySQL TCP checks"
  value       = aws_cloudwatch_log_group.proxysql.name
}

output "backend_test_request_example" {
  description = "Example request that is routed to the ECS backend instead of V1"
  value       = "curl -s -H '${var.backend_test_header_name}: ${var.backend_test_header_value}' https://${try(trimsuffix(data.terraform_remote_state.app.outputs.app_dns_record_fqdn, "."), "<app-domain>")}/api/"
}

output "market_http_service_name" {
  description = "market-http ECS service name (null until ai_image_tag is set)"
  value       = try(aws_ecs_service.market_http[0].name, null)
}

output "market_http_target_group_arn" {
  description = "Target group for market-http"
  value       = aws_lb_target_group.market_http.arn
}

output "market_http_task_security_group_id" {
  description = "Security group attached to market-http task ENIs"
  value       = aws_security_group.market_http_task.id
}

output "market_http_request_example" {
  description = "Example market-http request through the ALB"
  value       = "curl -s 'https://${try(trimsuffix(data.terraform_remote_state.app.outputs.app_dns_record_fqdn, "."), "<app-domain>")}${var.market_http_path_prefix}/prices?codes=005930'"
}

output "github_actions_ecs_deploy_role_arn" {
  description = "Role ARN for the AI repository AWS_ECS_DEPLOY_ROLE_ARN variable (cd-ecs-v2.yaml)"
  value       = aws_iam_role.github_actions_ecs_deploy.arn
}

output "github_actions_backend_deploy_role_arn" {
  description = "Role ARN for the BE repository AWS_V2_ECS_DEPLOY_ROLE_ARN secret (cd-ecs-v2.yaml)"
  value       = aws_iam_role.github_actions_backend_deploy.arn
}
