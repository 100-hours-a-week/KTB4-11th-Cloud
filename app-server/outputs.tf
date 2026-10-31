# Terraform이 생성한 주요 인프라 식별자를 출력한다.
# apply 결과 확인 및 향후 다른 Terraform 구성이나 자동화에서 참조할 수 있다.

# 애플리케이션 EC2에 연결할 Security Group ID
output "app_security_group_id" {
  description = "ID of the security group for the application EC2"
  value       = aws_security_group.app.id
}

output "app_instance_id" {
  description = "ID of the StockSpoon V1 application EC2 instance"
  value       = aws_instance.app.id
}

# V2 ECS Backend가 V1 MySQL에 접속하는 주소 (ecs 루트가 remote state로 참조)
# EC2를 교체하지 않는 한 stop/start에도 유지된다.
# TODO: V2 DB로 이전하면 ecs의 참조와 함께 제거
output "app_private_ip" {
  description = "Private IP of the V1 application EC2 (V1 MySQL host for V2 ECS backend tasks)"
  value       = aws_instance.app.private_ip
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

output "public_ecr_v2_backend_repository_uri" {
  description = "URI of the public ECR repository for V2 development backend images"
  value       = aws_ecrpublic_repository.backend_v2.repository_uri
}

output "public_ecr_v2_frontend_repository_uri" {
  description = "URI of the public ECR repository for V2 development frontend images"
  value       = aws_ecrpublic_repository.frontend_v2.repository_uri
}

output "github_actions_ecr_push_role_arn" {
  description = "IAM role ARN assumed by the backend GitHub Actions workflow"
  value       = aws_iam_role.github_actions_ecr_push.arn
}

output "github_actions_v2_dev_ecr_push_role_arn" {
  description = "IAM role ARN assumed by the Backend and Frontend dev workflows to push V2 images"
  value       = aws_iam_role.github_actions_v2_dev_ecr_push.arn
}

output "github_actions_oidc_provider_arn" {
  description = "ARN of the GitHub Actions OIDC provider"
  value       = aws_iam_openid_connect_provider.github_actions.arn
}

output "app_cloudwatch_agent_role_arn" {
  description = "IAM role attached to the application EC2 for CloudWatch Agent publishing"
  value       = aws_iam_role.app_cloudwatch_agent.arn
}

output "app_container_service_log_group_names" {
  description = "CloudWatch Logs groups receiving each Compose service's stdout/stderr"
  value       = { for service, log_group in aws_cloudwatch_log_group.app_container_services : service => log_group.name }
}

output "app_discord_webhook_secret_name" {
  description = "Secrets Manager secret where the Discord incoming webhook URL must be stored"
  value       = aws_secretsmanager_secret.app_discord_webhook.name
}

output "app_alert_email_from" {
  description = "Verified SES sender address for application alarm notifications"
  value       = local.app_alert_email_from
}

output "db_migration_host" {
  description = "Connection and disk identifiers for the migration target EC2"
  value = var.db_migration_enabled ? {
    instance_id       = aws_instance.db_migration[0].id
    instance_type     = aws_instance.db_migration[0].instance_type
    private_ip        = aws_instance.db_migration[0].private_ip
    public_ip         = aws_instance.db_migration[0].public_ip
    security_group_id = aws_security_group.db_migration[0].id
    root_volume_id    = aws_instance.db_migration[0].root_block_device[0].volume_id
    vpc_id            = data.terraform_remote_state.shared.outputs.vpc_id
    subnet_id         = data.terraform_remote_state.shared.outputs.public_subnet_id
  } : null
}

output "db_private_replica_host" {
  description = "Connection and disk identifiers for the private GTID MySQL replica"
  value = {
    instance_id       = aws_instance.db_private_replica.id
    instance_type     = aws_instance.db_private_replica.instance_type
    availability_zone = aws_instance.db_private_replica.availability_zone
    private_ip        = aws_instance.db_private_replica.private_ip
    security_group_id = aws_security_group.db_private_replica.id
    root_volume_id    = aws_instance.db_private_replica.root_block_device[0].volume_id
    vpc_id            = data.terraform_remote_state.shared.outputs.vpc_id
    subnet_id         = local.db_private_replica_subnet_id
  }
}

output "db_migration_support_hosts" {
  description = "Connection details for the API load generator and PMM EC2 hosts"
  value = {
    for role, instance in aws_instance.db_migration_support : role => {
      instance_id       = instance.id
      instance_type     = instance.instance_type
      private_ip        = instance.private_ip
      public_ip         = instance.public_ip
      security_group_id = aws_security_group.db_migration_support[role].id
      root_volume_id    = instance.root_block_device[0].volume_id
    }
  }
}

output "db_migration_pmm_url" {
  description = "PMM HTTPS UI; allowed only from db_migration_admin_cidrs"
  value       = var.db_migration_enabled ? "https://${aws_instance.db_migration_support["pmm"].public_ip}:8443" : null
}
