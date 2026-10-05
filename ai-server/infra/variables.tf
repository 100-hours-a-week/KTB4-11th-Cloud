variable "aws_region" {
  description = "AWS region containing the AI server"
  type        = string
  default     = "ap-northeast-2"
}

variable "ec2_key_name" {
  description = "Name of the existing EC2 Key Pair used for AI server SSH access"
  type        = string
  default     = "stockspoon-v1-deploy"
}

variable "ssh_allowed_cidrs" {
  description = "IPv4 CIDR blocks allowed to make key-only SSH connections to the AI server"
  type        = list(string)
  default     = ["0.0.0.0/0"]

  validation {
    condition = (
      length(var.ssh_allowed_cidrs) > 0 &&
      alltrue([for cidr in var.ssh_allowed_cidrs : can(cidrnetmask(cidr))])
    )
    error_message = "ssh_allowed_cidrs must contain at least one valid IPv4 CIDR block."
  }
}

variable "docker_compose_version" {
  description = "Pinned Docker Compose v2 release installed during AI EC2 bootstrap"
  type        = string
  default     = "v2.39.4"

  validation {
    condition     = can(regex("^v[0-9]+\\.[0-9]+\\.[0-9]+$", var.docker_compose_version))
    error_message = "docker_compose_version must use a tag such as v2.39.4."
  }
}

variable "ai_ec2_instance_type" {
  description = "EC2 instance type for the V1 AI host"
  type        = string
  default     = "t3a.medium"
}

variable "ai_ec2_ami_id" {
  description = "Pinned AMI ID for the V1 AI host to prevent unintended instance replacement"
  type        = string
  default     = "ami-0ebb55ce78339fc0c"
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
