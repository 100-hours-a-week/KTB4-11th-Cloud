output "ai_instance_id" {
  description = "ID of the StockSpoon V2 development AI EC2 instance"
  value       = aws_instance.ai.id
}

output "ai_public_ip" {
  description = "Elastic IP of the development AI EC2 instance"
  value       = aws_eip.ai.public_ip
}

output "ai_private_ip" {
  description = "Private IP used by the test-infra application host"
  value       = aws_instance.ai.private_ip
}

output "ai_security_group_id" {
  description = "Security Group attached to the development AI EC2 instance"
  value       = aws_security_group.ai.id
}

output "ai_iam_role_arn" {
  description = "ARN of the development AI EC2 IAM Role"
  value       = aws_iam_role.ai_ec2.arn
}

output "ai_instance_profile_name" {
  description = "Name of the development AI EC2 Instance Profile"
  value       = aws_iam_instance_profile.ai_ec2.name
}

output "report_queue_url" {
  description = "Report Queue URL written to the development AI host configuration"
  value       = data.terraform_remote_state.messaging.outputs.report_queue_url
}

output "order_queue_url" {
  description = "Order Queue URL written to the development AI host configuration"
  value       = data.terraform_remote_state.messaging.outputs.order_queue_url
}
