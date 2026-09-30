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
  default     = "stockspoon-v1-ai-app-use"
}

# 뉴스 전처리기 등 AI 애플리케이션의 구조화된 로그 그룹을 설정합니다.
variable "application_log_group" {
  description = "CloudWatch Logs group containing structured AI application logs"
  type        = string
  default     = "/stockspoon/ai/application"
}

# 커널 및 시스템 로그가 수집되는 AI 서버 로그 그룹을 설정합니다.
variable "system_log_group" {
  description = "CloudWatch Logs group containing AI host system logs"
  type        = string
  default     = "/stockspoon/ai/system"
}

# 계좌 및 모델 포트폴리오 업무 지표가 발행되는 네임스페이스를 설정합니다.
variable "business_metric_namespace" {
  description = "CloudWatch namespace for AI business metrics"
  type        = string
  default     = "Stockspoon/AI"
}

# Prometheus에서 전달된 vLLM 지표가 발행되는 CloudWatch 네임스페이스를 설정합니다.
variable "vllm_metric_namespace" {
  description = "CloudWatch namespace containing dimensionless vLLM metrics"
  type        = string
  default     = "Stockspoon/vLLM"
}
