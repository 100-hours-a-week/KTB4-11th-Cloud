# Terraform이 생성한 주요 인프라 식별자를 출력한다.
# apply 결과 확인 및 향후 다른 Terraform 구성이나 자동화에서 참조할 수 있다.

# StockSpoon V1에서 사용하는 VPC ID
output "vpc_id" {
  description = "ID of the StockSpoon V1 VPC"
  value       = aws_vpc.main.id
}

# 애플리케이션 EC2가 배치될 Public Subnet ID
output "public_subnet_id" {
  description = "ID of the public subnet for the application EC2"
  value       = aws_subnet.public.id
}

# 애플리케이션 EC2에 연결할 Security Group ID
output "app_security_group_id" {
  description = "ID of the security group for the application EC2"
  value       = aws_security_group.app.id
}

output "app_instance_id" {
  description = "ID of the StockSpoon V1 application EC2 instance"
  value       = aws_instance.app.id
}

output "app_public_ip" {
  description = "Elastic IP used as the EC2_HOST GitHub Environment secret"
  value       = aws_eip.app.public_ip
}

output "app_public_dns" {
  description = "Public DNS name of the application EC2 instance"
  value       = aws_eip.app.public_dns
}

output "app_ssh_user" {
  description = "SSH username used as the EC2_USER GitHub Environment secret"
  value       = "ubuntu"
}

output "public_ecr_repository_uri" {
  description = "URI of the public ECR repository for backend images"
  value       = aws_ecrpublic_repository.backend.repository_uri
}

output "public_ecr_frontend_repository_uri" {
  description = "URI of the public ECR repository for frontend images"
  value       = aws_ecrpublic_repository.frontend.repository_uri
}

output "public_ecr_ai_repository_uri" {
  description = "URI of the public ECR repository for AI images"
  value       = aws_ecrpublic_repository.ai.repository_uri
}

output "github_actions_ecr_push_role_arn" {
  description = "IAM role ARN assumed by the backend GitHub Actions workflow"
  value       = aws_iam_role.github_actions_ecr_push.arn
}

output "github_actions_oidc_provider_arn" {
  description = "ARN of the GitHub Actions OIDC provider"
  value       = aws_iam_openid_connect_provider.github_actions.arn
}

output "github_cloud_deploy_role_arn" {
  description = "IAM role ARN used by Cloud CD to verify deployment images"
  value       = aws_iam_role.github_cloud_deploy.arn
}
