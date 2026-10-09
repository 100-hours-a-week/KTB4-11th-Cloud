variable "aws_region" {
  description = "AWS region for the load-test infrastructure"
  type        = string
  default     = "ap-northeast-2"
}

variable "name_prefix" {
  description = "Prefix used to keep load-test resource names separate from production"
  type        = string
  default     = "stockspoon-loadtest"

  validation {
    condition     = can(regex("^[a-z0-9-]{1,40}$", var.name_prefix))
    error_message = "name_prefix must contain 1-40 lowercase letters, numbers, or hyphens."
  }
}

variable "vpc_cidr" {
  description = "CIDR block for the isolated load-test VPC; must not overlap existing VPCs"
  type        = string
  default     = "10.20.0.0/16"
}

variable "public_subnet_cidr" {
  description = "CIDR block for the public subnet that hosts both EC2 instances"
  type        = string
  default     = "10.20.1.0/24"
}

variable "availability_zone" {
  description = "Availability Zone for the load-test public subnet"
  type        = string
  default     = "ap-northeast-2a"
}

variable "private_subnets" {
  description = "Private subnets shared by development services in this VPC"
  type = map(object({
    cidr_block        = string
    availability_zone = string
  }))

  default = {
    a = {
      cidr_block        = "10.20.10.0/24"
      availability_zone = "ap-northeast-2a"
    }
    c = {
      cidr_block        = "10.20.11.0/24"
      availability_zone = "ap-northeast-2c"
    }
  }

  validation {
    condition = (
      length(var.private_subnets) >= 2 &&
      alltrue([
        for subnet in values(var.private_subnets) : can(cidrnetmask(subnet.cidr_block))
      ]) &&
      length(distinct([
        for subnet in values(var.private_subnets) : subnet.availability_zone
      ])) == length(var.private_subnets)
    )
    error_message = "private_subnets must contain at least two valid CIDRs in distinct availability zones."
  }
}

variable "ec2_key_name" {
  description = "Existing EC2 key pair name; SSM Session Manager is also enabled"
  type        = string
  default     = "stockspoon-v1-deploy"
}

variable "ssh_allowed_cidrs" {
  description = "IPv4 CIDR blocks allowed to SSH to both test EC2s; defaults to open like infra"
  type        = list(string)
  default     = ["0.0.0.0/0"]

  validation {
    condition     = alltrue([for cidr in var.ssh_allowed_cidrs : can(cidrnetmask(cidr))])
    error_message = "ssh_allowed_cidrs must contain only valid IPv4 CIDR blocks."
  }
}

variable "app_instance_type" {
  description = "EC2 instance type for the application host (defaults to the current V1 host size)"
  type        = string
  default     = "t3a.medium"
}

variable "k6_instance_type" {
  description = "EC2 instance type for the k6 load generator"
  type        = string
  default     = "t3a.medium"
}

variable "app_root_volume_size_gib" {
  description = "Encrypted gp3 root volume size for the application EC2"
  type        = number
  default     = 30

  validation {
    condition     = var.app_root_volume_size_gib >= 8
    error_message = "app_root_volume_size_gib must be at least 8 GiB."
  }
}

variable "k6_root_volume_size_gib" {
  description = "Encrypted gp3 root volume size for the k6 EC2"
  type        = number
  default     = 20

  validation {
    condition     = var.k6_root_volume_size_gib >= 8
    error_message = "k6_root_volume_size_gib must be at least 8 GiB."
  }
}

variable "github_repository_owner" {
  description = "GitHub user or organization that owns the Cloud repository"
  type        = string
  default     = "100-hours-a-week"
}

variable "github_cloud_repository_name" {
  description = "Cloud repository cloned onto the test application host"
  type        = string
  default     = "KTB4-11th-Cloud"
}

variable "github_deployment_branch" {
  description = "Branch of the Cloud repository cloned onto the test application host"
  type        = string
  default     = "main"
}

variable "docker_compose_version" {
  description = "Pinned Docker Compose v2 release installed on the application host"
  type        = string
  default     = "v2.39.4"

  validation {
    condition     = can(regex("^v[0-9]+[.][0-9]+[.][0-9]+$", var.docker_compose_version))
    error_message = "docker_compose_version must use a tag such as v2.39.4."
  }
}
