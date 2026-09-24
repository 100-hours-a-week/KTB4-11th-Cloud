variable "ai_ec2_instance_type" {
  description = "EC2 instance type for the V1 AI host"
  type        = string
  default     = "t3a.medium"
}

variable "ai_ec2_root_volume_size_gib" {
  description = "Encrypted gp3 root EBS volume size for the AI EC2 host"
  type        = number
  default     = 30

  validation {
    condition     = var.ai_ec2_root_volume_size_gib >= 8
    error_message = "ai_ec2_root_volume_size_gib must be at least 8 GiB."
  }
}
