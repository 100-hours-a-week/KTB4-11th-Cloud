variable "aws_region" {
  description = "AWS region"
  type        = string
  default     = "ap-northeast-2"
}

variable "vpc_cidr" {
  description = "CIDR block for the VPC"
  type        = string
  default     = "10.0.0.0/16"
}

variable "public_subnet_cidr" {
  description = "CIDR block for the public subnet"
  type        = string
  default     = "10.0.1.0/24"
}

variable "ec2_instance_type" {
  description = "EC2 instance type for the V1 application host"
  type        = string
  default     = "t3a.medium"
}

variable "ec2_key_name" {
  description = "Name of the existing EC2 Key Pair used for deployment SSH access"
  type        = string
  default     = "stockspoon-v1-deploy"
}

variable "ec2_root_volume_size_gib" {
  description = "Size in GiB of the encrypted gp3 root EBS volume"
  type        = number
  default     = 30

  validation {
    condition     = var.ec2_root_volume_size_gib >= 8
    error_message = "ec2_root_volume_size_gib must be at least 8 GiB."
  }
}

variable "ssh_allowed_cidrs" {
  description = "IPv4 CIDR blocks allowed to make key-only SSH connections"
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
  description = "Pinned Docker Compose v2 release installed during EC2 bootstrap"
  type        = string
  default     = "v2.39.4"

  validation {
    condition     = can(regex("^v[0-9]+\\.[0-9]+\\.[0-9]+$", var.docker_compose_version))
    error_message = "docker_compose_version must use a tag such as v2.39.4."
  }
}

variable "public_ecr_repository_name" {
  description = "Name of the public ECR repository for the backend application"
  type        = string
  default     = "stockspoon-v1-backend"
}

variable "public_ecr_frontend_repository_name" {
  description = "Name of the public ECR repository for the frontend application"
  type        = string
  default     = "stockspoon-v1-frontend"
}

variable "public_ecr_ai_repository_name" {
  description = "Name of the public ECR repository for the AI application"
  type        = string
  default     = "stockspoon-v1-ai"
}

variable "github_repository_owner" {
  description = "GitHub organization or user that owns the backend repository"
  type        = string
  default     = "100-hours-a-week"
}

variable "github_repository_name" {
  description = "GitHub backend repository allowed to push images"
  type        = string
  default     = "KTB4-11th-BE"
}

variable "github_frontend_repository_name" {
  description = "GitHub frontend repository allowed to push images"
  type        = string
  default     = "KTB4-11th-FE"
}

variable "github_ai_repository_name" {
  description = "GitHub AI repository allowed to push images"
  type        = string
  default     = "KTB4-11th-AI"
}

variable "github_cloud_repository_name" {
  description = "GitHub Cloud repository allowed to validate and deploy images"
  type        = string
  default     = "KTB4-11th-Cloud"
}

variable "github_deployment_branch" {
  description = "GitHub branch allowed to assume the ECR push role"
  type        = string
  default     = "main"
}
