output "managed_iam_user_names" {
  description = "Existing IAM users managed by this Terraform root"
  value       = sort(keys(aws_iam_user.existing))
}

output "managed_iam_group_names" {
  description = "Existing IAM groups managed by this Terraform root"
  value       = sort(keys(aws_iam_group.existing))
}
