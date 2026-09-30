# AI 서버와 대시보드가 위치한 AWS 리전을 설정합니다.
variable "aws_region" {
  description = "AWS region containing the AI instance"
  type        = string
  default     = "ap-northeast-2"
}

# 대시보드에서 조회할 AI EC2 인스턴스 ID를 설정합니다.
variable "ai_instance_id" {
  description = "AI EC2 instance ID"
  type        = string
  default     = "i-04ab95c711878616c"
}

# CloudWatch Agent 지표 dimension에 사용할 AI EC2 인스턴스 타입을 설정합니다.
variable "ai_instance_type" {
  description = "AI EC2 instance type used by AI_CWAgent dimensions"
  type        = string
  default     = "t3a.medium"
}

# 생성할 AI 전용 CloudWatch 대시보드 이름을 설정합니다.
variable "dashboard_name" {
  description = "AI-only CloudWatch dashboard name"
  type        = string
  default     = "stockspoon-v1-ai-basic"
}
