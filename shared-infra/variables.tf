variable "aws_region" {
  description = "AWS region containing the shared infrastructure"
  type        = string
  default     = "ap-northeast-2"
}

variable "vpc_cidr" {
  description = "CIDR block for the shared VPC"
  type        = string
  default     = "10.0.0.0/16"
}

variable "public_subnet_cidr" {
  description = "CIDR block for the shared public subnet"
  type        = string
  default     = "10.0.1.0/24"
}

variable "public_subnet_c_cidr" {
  description = "CIDR block for the second public subnet in ap-northeast-2c, used by the ALB"
  type        = string
  default     = "10.0.2.0/24"
}

variable "private_subnets" {
  description = "Private subnets for ECS container instances, keyed by AZ suffix"
  type = map(object({
    cidr_block        = string
    availability_zone = string
  }))

  default = {
    a = {
      cidr_block        = "10.0.11.0/24"
      availability_zone = "ap-northeast-2a"
    }
    c = {
      cidr_block        = "10.0.12.0/24"
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
