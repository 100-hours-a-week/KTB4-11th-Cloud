output "target_vpc_id" {
  description = "ID of the test-infra VPC reused by the development Valkey cache"
  value       = data.terraform_remote_state.test.outputs.vpc_id
}

output "ai_dev_security_group_id" {
  description = "Security Group ID of the V2 development AI server"
  value       = data.terraform_remote_state.ai_dev.outputs.ai_security_group_id
}

output "ai_dev_iam_role_arn" {
  description = "IAM Role ARN of the V2 development AI server"
  value       = data.terraform_remote_state.ai_dev.outputs.ai_iam_role_arn
}

output "valkey_private_subnet_ids" {
  description = "IDs of the test-infra private subnets used by the Valkey serverless cache"
  value       = data.terraform_remote_state.test.outputs.private_subnet_ids
}

output "valkey_security_group_id" {
  description = "ID of the Security Group attached to the Valkey serverless cache"
  value       = aws_security_group.valkey.id
}
