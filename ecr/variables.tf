variable "aws_region" {
  description = "AWS region for the private ECR repositories"
  type        = string
  default     = "ap-northeast-2"
}

# stockspoon-{버전}-{환경}-{서비스} 형식을 사용한다. (IAM 접두사 stockspoon-v2-dev-*, stockspoon-v2-prod-*와 동일한 규칙)
# Terraform CI 권한이 이 이름 목록으로 제한되어 있으므로, 추가 시 CI 권한도 함께 갱신한다.
variable "repository_names" {
  description = "Private ECR repository names"
  type        = set(string)
  default     = ["stockspoon-v2-prod-backend", "stockspoon-v2-prod-frontend"]
}

variable "keep_image_count" {
  description = "Number of images to keep in each repository"
  type        = number
  default     = 30
}

variable "untagged_expire_days" {
  description = "Days after which untagged images are removed"
  type        = number
  default     = 7
}
