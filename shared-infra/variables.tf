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
