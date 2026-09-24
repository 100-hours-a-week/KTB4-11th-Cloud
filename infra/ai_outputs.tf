output "ai_instance_id" {
  description = "ID of the StockSpoon V1 AI EC2 instance"
  value       = aws_instance.ai.id
}

output "ai_public_ip" {
  description = "Auto-assigned public IP for initial SSH access to the AI host"
  value       = aws_instance.ai.public_ip
}

output "ai_private_ip" {
  description = "Private IP for application-to-AI traffic inside the VPC"
  value       = aws_instance.ai.private_ip
}

output "ai_security_group_id" {
  description = "Security group attached to the AI EC2 instance"
  value       = aws_security_group.ai.id
}
