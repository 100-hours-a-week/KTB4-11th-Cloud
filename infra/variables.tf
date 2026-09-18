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

variable "public_ecr_repository_name" {
  description = "Name of the public ECR repository for the backend application"
  type        = string
  default     = "stockspoon-v1-backend"
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

variable "github_deployment_branch" {
  description = "GitHub branch allowed to assume the ECR push role"
  type        = string
  default     = "main"
}
