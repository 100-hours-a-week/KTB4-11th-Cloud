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

# BE 레포 dev CI가 Public ECR(stockspoon-v2-backend)에 push한 이미지 태그(dev 커밋 SHA)
variable "backend_image_tag" {
  description = "Tag (git SHA) of the backend image in the public ECR repository stockspoon-v2-backend"
  type        = string
  default     = "1625d25411026f0828ff545393e9de8970c58711"
}

variable "backend_container_port" {
  description = "Container port exposed by the backend"
  type        = number
  default     = 8080
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

# V1 Backend와 같은 DB를 쓰는 동안은 1개로 둔다.
# dev 코드의 주기 작업(만료 주문 정리 등)이 V1과 함께 운영 DB에 쓰므로, 동시 실행 안전성을 BE와 확인한 뒤 늘린다.
variable "backend_desired_count" {
  description = "Number of backend tasks"
  type        = number
  default     = 1
}

variable "backend_stop_timeout_seconds" {
  description = "Time to wait for graceful shutdown after SIGTERM before SIGKILL (max 120 on Linux)"
  type        = number
  default     = 30
}

# Backend에 actuator가 없어 인증 없이 200을 주는 경로를 임시로 사용한다. (Spring Security로 /는 401/403)
# 이 경로는 DB·Valkey 상태를 반영하지 않는다. TODO: BE에 /actuator/health 추가 후 교체
variable "backend_health_check_path" {
  description = "ALB health check path for the backend target group"
  type        = string
  default     = "/api/v1/auth/csrf"
}

variable "backend_health_check_grace_period_seconds" {
  description = "Time ECS ignores failing ALB health checks after a task starts"
  type        = number
  default     = 120 # Spring Boot 1 vCPU 기동(V1 Compose start_period 40s) + DB·Valkey 연결 여유
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

# 경로 기반 라우팅: Backend는 /api/*, Socket(market-http)은 /market/*
variable "backend_path_patterns" {
  description = "ALB path patterns routed to the ECS backend"
  type        = list(string)
  default     = ["/api/*"]
}

variable "v1_mysql_port" {
  description = "MySQL port published on the V1 application host"
  type        = number
  default     = 3306
}

variable "backend_mysql_database" {
  description = "V1 MySQL database name (MYSQL_DATABASE in the V1 .env)"
  type        = string
  default     = "stockspoon"
}

# V1 .env의 KAKAO_CLIENT_SECRET이 비어 있으면 false로 둔다. (SSM에는 빈 값을 저장할 수 없음)
variable "backend_kakao_client_secret_enabled" {
  description = "Inject KAKAO_CLIENT_SECRET from SSM; false injects an empty value"
  type        = bool
  default     = true
}

variable "backend_test_rule_priority" {
  description = "Priority of the test listener rule on the HTTPS listener"
  type        = number
  default     = 100
}

# ---------------------------------------------------------------------------
# AI market-http
# ---------------------------------------------------------------------------

# AI CI Dev가 Public ECR(stockspoon-v1-ai)에 push한 통합 이미지의 태그(dev 커밋 SHA)
# 비어 있으면 Task Definition과 ECS Service를 만들지 않고 SG·Target Group·리스너 규칙 등만 준비한다.
# 서비스를 처음 만들 때만 쓰이며, 이후 이미지 배포는 AI 레포 cd-ecs-v2.yaml이 담당한다.
variable "ai_image_tag" {
  description = "Tag (git SHA) of the AI app image in the public ECR repository; empty skips task definitions and services"
  type        = string
  default     = "339f334d22a8c17aff3bc3a8c4ec24e361b730fc"
}

variable "ai_questdb_http_port" {
  description = "QuestDB HTTP port published on the V1 AI host private IP"
  type        = number
  default     = 9000
}

# ---------------------------------------------------------------------------
# market-http (Socket: 현재가 REST·SSE, 과거 시세)
# ---------------------------------------------------------------------------

variable "market_http_container_port" {
  description = "Container port exposed by market-http"
  type        = number
  default     = 8000
}

# uvicorn 단일 프로세스(이벤트 루프 1개)라 1 vCPU를 넘게 줘도 쓰지 못한다. Task 수로 확장한다.
variable "market_http_task_cpu" {
  description = "market-http task CPU units (1024 = 1 vCPU)"
  type        = number
  default     = 1024
}

variable "market_http_task_memory" {
  description = "market-http task memory (MiB)"
  type        = number
  default     = 1024
}

variable "market_http_desired_count" {
  description = "Number of market-http tasks"
  type        = number
  default     = 2
}

# ALB 경로 접두사. 앱은 루트 경로(/prices, /bars, ...)를 제공하므로 ALB가 접두사를 제거해 전달한다.
variable "market_http_path_prefix" {
  description = "ALB path prefix for market-http; stripped before forwarding"
  type        = string
  default     = "/market"
}

variable "market_http_rule_priority" {
  description = "Priority of the market-http rule on the HTTPS listener"
  type        = number
  default     = 200
}

# SSE 연결은 delay가 끝나면 끊기고 EventSource가 재연결한다. 재연결 시 snapshot을 다시 받으므로 짧게 둔다.
variable "market_http_deregistration_delay_seconds" {
  description = "Time the ALB keeps existing (SSE) connections to a deregistering target"
  type        = number
  default     = 30
}

variable "market_http_stop_timeout_seconds" {
  description = "Time to wait after SIGTERM before SIGKILL"
  type        = number
  default     = 30
}

variable "market_http_health_check_grace_period_seconds" {
  description = "Time ECS ignores failing ALB health checks after a task starts"
  type        = number
  default     = 30
}

variable "market_http_log_level" {
  description = "market-http log level"
  type        = string
  default     = "INFO"
}

# ---------------------------------------------------------------------------
# GitHub Actions ECS 배포 (AI 레포 cd-ecs-v2.yaml)
# ---------------------------------------------------------------------------

# GitHub OIDC sub 클레임. 이 조직은 owner·repo 이름 뒤에 불변 ID가 붙는 형식을 쓴다. (app-server/github_oidc.tf와 동일)
variable "ecs_deploy_github_subjects" {
  description = "GitHub OIDC subjects allowed to deploy the AI market services to ECS"
  type        = list(string)
  default = [
    "repo:100-hours-a-week@167328634/KTB4-11th-AI@1372520303:ref:refs/heads/dev",
  ]
}
