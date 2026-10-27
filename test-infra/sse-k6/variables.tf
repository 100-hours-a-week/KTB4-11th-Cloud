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

variable "sse_k6_instance_type" {
  description = "EC2 instance type for the dedicated SSE load generator"
  type        = string
  default     = "c7i.xlarge"
}

variable "sse_k6_root_volume_size_gib" {
  description = "Encrypted gp3 root volume size for the dedicated SSE load generator"
  type        = number
  default     = 20

  validation {
    condition     = var.sse_k6_root_volume_size_gib >= 8
    error_message = "sse_k6_root_volume_size_gib must be at least 8 GiB."
  }
}

variable "sse_k6_k6_version" {
  description = "Pinned k6 version for the custom SSE binary, matching the existing load generator"
  type        = string
  default     = "v1.1.0"
}

variable "sse_k6_xk6_version" {
  description = "Pinned xk6 builder version for the dedicated SSE load generator"
  type        = string
  default     = "v1.4.15"
}

variable "sse_k6_extension_version" {
  description = "Pinned phymbert/xk6-sse extension version, matching the existing load generator"
  type        = string
  default     = "v0.1.11"
}

variable "sse_vpc_peering_connection_id" {
  description = "Existing test/production VPC peering managed by monitoring"
  type        = string
  default     = "pcx-0ce88aa1e25be2dc0"
}

variable "sse_container_port" {
  description = "market-http HTTP/SSE container port"
  type        = number
  default     = 8000
}
