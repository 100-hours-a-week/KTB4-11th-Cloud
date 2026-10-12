output "repository_urls" {
  description = "Private ECR repository URLs keyed by repository name"
  value       = { for name, repo in aws_ecr_repository.this : name => repo.repository_url }
}

output "repository_arns" {
  description = "Private ECR repository ARNs keyed by repository name"
  value       = { for name, repo in aws_ecr_repository.this : name => repo.arn }
}
