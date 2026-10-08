variable "aws_region" {
  description = "AWS region containing the V2 development AI server"
  type        = string
  default     = "ap-northeast-2"
}

variable "ec2_key_name" {
  description = "Existing EC2 Key Pair used for optional SSH access"
  type        = string
  default     = "stockspoon-v1-deploy"
}

variable "ssh_allowed_cidrs" {
  description = "IPv4 CIDR blocks allowed to make key-only SSH connections; leave empty when using SSM or Tailscale"
  type        = list(string)
  default     = []

  validation {
    condition     = alltrue([for cidr in var.ssh_allowed_cidrs : can(cidrnetmask(cidr))])
    error_message = "ssh_allowed_cidrs must contain only valid IPv4 CIDR blocks."
  }
}

variable "docker_compose_version" {
  description = "Pinned Docker Compose v2 release installed during EC2 bootstrap"
  type        = string
  default     = "v2.39.4"

  validation {
    condition     = can(regex("^v[0-9]+\\.[0-9]+\\.[0-9]+$", var.docker_compose_version))
    error_message = "docker_compose_version must use a tag such as v2.39.4."
  }
}

variable "ai_ec2_instance_type" {
  description = "EC2 instance type for the V2 development AI host"
  type        = string
  default     = "t3a.medium"
}

variable "ai_ec2_ami_id" {
  description = "Pinned Ubuntu AMI ID for the V2 development AI host"
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

variable "ai_api_port" {
  description = "TCP port exposed by the AI API"
  type        = number
  default     = 8000

  validation {
    condition     = var.ai_api_port >= 1 && var.ai_api_port <= 65535
    error_message = "ai_api_port must be between 1 and 65535."
  }
}

variable "test_app_security_group_name" {
  description = "Name of the test-infra application Security Group allowed to call the AI API"
  type        = string
  default     = "stockspoon-loadtest-app-sg"
}

variable "tailscale_auth_parameter_name" {
  description = "Existing SSM SecureString containing the reusable Tailscale authentication key"
  type        = string
  default     = "/stockspoon/ai/tailscale-auth-key"
}
