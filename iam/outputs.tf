output "managed_iam_user_names" {
  description = "Existing IAM users managed by this Terraform root"
  value       = sort(keys(aws_iam_user.existing))
}

output "managed_iam_group_names" {
  description = "IAM groups managed by this Terraform root"
  value       = sort(concat(keys(aws_iam_group.existing), [aws_iam_group.ai_server_viewer.name]))
}
