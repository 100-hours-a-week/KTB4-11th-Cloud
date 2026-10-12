variable "aws_region" {
  description = "AWS region for the ECS stack"
  type        = string
  default     = "ap-northeast-2"
}

# Terraform CI 권한이 stockspoon-v2-prod-* 접두사로 제한되어 있으므로 바꾸지 않는다.
variable "name_prefix" {
  description = "Name prefix for production ECS resources (must match the Terraform CI permission scope)"
  type        = string
  default     = "stockspoon-v2-prod"
}

variable "ssm_parameter_path_prefix" {
  description = "SSM Parameter Store path prefix that ECS tasks can read secrets from"
  type        = string
  default     = "/stockspoon/v2/prod"
}

variable "container_log_retention_days" {
  description = "Retention period for ECS container logs"
  type        = number
  default     = 30
}

# ---------------------------------------------------------------------------
# Service ASG (Backend + Socket)
# ---------------------------------------------------------------------------

# 기준 Task 조합(Backend 1 vCPU/1 GiB + Socket 2 vCPU/4 GiB)에 20% Headroom을 적용한
# 3.75 vCPU / 6.25 GiB를 충족하고, ENI Trunking을 지원하는 x86 타입 (t3a 계열은 미지원)
variable "service_instance_type" {
  description = "Instance type for the service ASG (must support ENI trunking)"
  type        = string
  default     = "c6i.xlarge"
}

variable "service_asg_min_size" {
  description = "Minimum number of service ASG instances (one per AZ)"
  type        = number
  default     = 2
}

variable "service_asg_max_size" {
  description = "Maximum number of service ASG instances"
  type        = number
  default     = 4
}

variable "service_root_volume_size_gib" {
  description = "Root EBS volume size for service ASG instances"
  type        = number
  default     = 30
}

# Headroom은 인스턴스 크기에서 20% 확보하므로 Capacity Provider 여유분은 두지 않는다.
variable "service_target_capacity" {
  description = "Capacity provider managed scaling target capacity (percent)"
  type        = number
  default     = 100
}

# Task Definition의 stopTimeout을 지정하지 않은 컨테이너에 적용되는 기본 종료 대기 시간
variable "ecs_container_stop_timeout_seconds" {
  description = "Default time the ECS agent waits before force-killing a container"
  type        = number
  default     = 30
}

# ---------------------------------------------------------------------------
# Backend Service
# ---------------------------------------------------------------------------

# 실제 Backend 이미지 전달 전에는 테스트용 nginx 이미지로 인프라 동작을 검증한다.
variable "backend_container_image" {
  description = "Container image for the backend service"
  type        = string
  default     = "public.ecr.aws/nginx/nginx:stable"
}

variable "backend_container_port" {
  description = "Container port exposed by the backend"
  type        = number
  default     = 80
}

variable "backend_task_cpu" {
  description = "Backend task CPU units (1024 = 1 vCPU)"
  type        = number
  default     = 1024
}

variable "backend_task_memory" {
  description = "Backend task memory (MiB)"
  type        = number
  default     = 1024
}

variable "backend_desired_count" {
  description = "Number of backend tasks"
  type        = number
  default     = 2
}

variable "backend_stop_timeout_seconds" {
  description = "Time to wait for graceful shutdown after SIGTERM before SIGKILL (max 120 on Linux)"
  type        = number
  default     = 30
}

variable "backend_health_check_path" {
  description = "ALB health check path for the backend target group"
  type        = string
  default     = "/"
}

variable "backend_health_check_grace_period_seconds" {
  description = "Time ECS ignores failing ALB health checks after a task starts"
  type        = number
  default     = 60
}

variable "backend_deregistration_delay_seconds" {
  description = "Time the ALB waits for in-flight requests before deregistering a target"
  type        = number
  default     = 60
}

# 3장 완료 후 Rolling(ECS) / ECS 네이티브 Blue-Green 중 결정한다.
variable "backend_deployment_controller" {
  description = "ECS deployment controller type"
  type        = string
  default     = "ECS"
}

# 운영 트래픽에 영향 없이 Green(ECS)을 검증하기 위한 헤더 조건
# 이 헤더가 있는 요청만 Green Target Group으로 전달된다.
variable "backend_test_header_name" {
  description = "HTTP header that routes test requests to the ECS backend"
  type        = string
  default     = "X-StockSpoon-Target"
}

variable "backend_test_header_value" {
  description = "Header value that routes test requests to the ECS backend"
  type        = string
  default     = "ecs"
}

variable "backend_test_rule_priority" {
  description = "Priority of the test listener rule on the HTTPS listener"
  type        = number
  default     = 100
}
