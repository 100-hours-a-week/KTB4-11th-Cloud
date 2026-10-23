output "sse_k6_instance_id" {
  description = "ID of the dedicated SSE load generator EC2"
  value       = aws_instance.sse_k6.id
}

output "sse_k6_public_ip" {
  description = "Public IP of the dedicated SSE load generator; can change after stop/start or replacement"
  value       = aws_instance.sse_k6.public_ip
}

output "sse_k6_private_ip" {
  description = "Private IP of the dedicated SSE load generator in the existing load-test VPC"
  value       = aws_instance.sse_k6.private_ip
}

output "sse_k6_security_group_id" {
  description = "Dedicated SSE generator security group allowed on the production SSE HTTP port"
  value       = aws_security_group.sse_k6.id
}

output "sse_k6_iam_role_name" {
  description = "Dedicated IAM role for the SSE load generator"
  value       = aws_iam_role.sse_k6.name
}
