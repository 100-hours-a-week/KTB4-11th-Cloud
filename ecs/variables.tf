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

variable "observability_log_retention_days" {
  description = "Retention for ECS performance, lifecycle events, and experiment logs"
  type        = number
  default     = 30

  validation {
    condition     = contains([7, 14, 30, 60, 90, 120, 150, 180, 365], var.observability_log_retention_days)
    error_message = "Choose a supported retention of at least 7 days."
  }
}

variable "observability_alarm_actions" {
  description = "Optional SNS/action ARNs for service health alarms; empty keeps alarms observable without notifications"
  type        = list(string)
  default     = []
}

# 두 서비스 모두 평일 08:40~15:40에는 최소 3개, 그 외에는 최소 2개를 유지한다.
variable "service_preopen_scaling" {
  description = "Paired schedules in Asia/Seoul; both services default to minimum 3 at 08:40 and minimum 2 at 15:40 on weekdays"
  type = map(object({
    min_capacity     = number
    preopen_schedule = string
    restore_schedule = string
  }))
  default = {
    backend = {
      min_capacity     = 3
      preopen_schedule = "cron(40 8 ? * MON-FRI *)"
      restore_schedule = "cron(40 15 ? * MON-FRI *)"
    }
    market-http = {
      min_capacity     = 3
      preopen_schedule = "cron(40 8 ? * MON-FRI *)"
      restore_schedule = "cron(40 15 ? * MON-FRI *)"
    }
  }

  validation {
    condition = alltrue([
      for service, config in var.service_preopen_scaling :
      contains(["backend", "market-http"], service) &&
      contains([3, 4], config.min_capacity) &&
      can(regex("^cron\\(.+\\)$", config.preopen_schedule)) &&
      can(regex("^cron\\(.+\\)$", config.restore_schedule)) &&
      config.preopen_schedule != config.restore_schedule &&
      (service != "backend" || (
        config.min_capacity == 3 && config.preopen_schedule == "cron(40 8 ? * MON-FRI *)"
      ))
    ])
    error_message = "Use backend/market-http keys, minimum 3 or 4, and distinct cron schedules; backend preopen must be weekdays at 08:40 with minimum 3."
  }
}

# ---------------------------------------------------------------------------
# Service ASG (Backend + Socket)
# ---------------------------------------------------------------------------

# 인스턴스당 Backend 1 vCPU/2 GiB + SSE 2 vCPU/4 GiB를 기본 조합으로 배치한다.
# c6i.xlarge(4 vCPU/8 GiB)의 남은 자원은 OS·ECS Agent와 추가 Task에 사용한다.
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

# Capacity Provider에서 별도 예비 인스턴스 용량은 두지 않는다.
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
# Task Definition의 기준 리비전에만 쓰인다. 서비스가 실제로 실행하는 이미지는 BE 레포 cd-ecs-dev.yaml이 배포한다.
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

# ProxySQL은 우선 네트워크 경로 검증용으로 단일 AZ에 1개만 띄운다.
variable "proxysql_image" {
  description = "Pinned public ProxySQL container image for the migration rehearsal"
  type        = string
  default     = "proxysql/proxysql:3.0.11"
}

variable "proxysql_task_cpu" {
  description = "ProxySQL ECS task CPU units (1024 = 1 vCPU)"
  type        = number
  default     = 512
}

variable "proxysql_task_memory" {
  description = "ProxySQL ECS task memory in MiB"
  type        = number
  default     = 1024
}

variable "backend_task_cpu" {
  description = "Backend task CPU units (1024 = 1 vCPU)"
  type        = number
  default     = 1024
}

variable "backend_task_memory" {
  description = "Backend task memory (MiB)"
  type        = number
  default     = 2048
}

# Backend Task는 AZ와 인스턴스에 분산해 2개를 유지한다.
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

# true면 SSM의 키움 키(V1과 별도 발급)를 주입하고 시세 스트림을 켠다.
# V1 Backend와 같은 DB의 PENDING 지정가 주문을 두 서버가 함께 체결하려 해도,
# V1(main)·dev 모두 executeLimit에서 계좌 행 비관적 락 후 주문 상태를 재확인하므로 한쪽만 체결된다.
variable "backend_kiwoom_stream_enabled" {
  description = "Inject Kiwoom API keys from SSM and enable the Kiwoom market stream in the backend"
  type        = bool
  default     = true
}

variable "backend_canary_enabled" {
  description = "Enable weighted routing for all backend API requests; false sends API requests through the default V1 route"
  type        = bool
  default     = true
}

variable "backend_canary_green_weight" {
  description = "V2 traffic weight from 0 to 100; V1 receives the remaining weight"
  type        = number
  default     = 0

  validation {
    condition = (
      var.backend_canary_green_weight >= 0 &&
      var.backend_canary_green_weight <= 100 &&
      floor(var.backend_canary_green_weight) == var.backend_canary_green_weight
    )
    error_message = "backend_canary_green_weight must be an integer between 0 and 100."
  }
}

variable "backend_canary_rule_priority" {
  description = "Priority of the weighted API rule on the HTTPS listener"
  type        = number
  default     = 100

  validation {
    condition = (
      var.backend_canary_rule_priority >= 1 &&
      var.backend_canary_rule_priority <= 50000 &&
      floor(var.backend_canary_rule_priority) == var.backend_canary_rule_priority &&
      var.backend_canary_rule_priority != var.market_http_rule_priority
    )
    error_message = "Canary priority must be an integer from 1 to 50000 and different from market_http_rule_priority."
  }
}

# ---------------------------------------------------------------------------
# AI market-http
# ---------------------------------------------------------------------------

# AI 서비스 최초 생성에 사용할 검증된 이미지 태그. 이후 Task Definition은 앱 CD가 관리한다.
# 비어 있으면 Task Definition과 ECS Service를 만들지 않고 SG·Target Group·리스너 규칙 등만 준비한다.
variable "ai_image_tag" {
  description = "Bootstrap AI image tag; subsequent task definitions are app-CD owned; empty skips AI services"
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

# SSE 서버 초기 설계값. 단일 uvicorn 프로세스의 실제 처리량은 부하 테스트로 검증한다.
variable "market_http_task_cpu" {
  description = "market-http task CPU units (1024 = 1 vCPU)"
  type        = number
  default     = 2048
}

variable "market_http_task_memory" {
  description = "market-http task memory (MiB)"
  type        = number
  default     = 4096
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

# BE 레포 ci-dev.yaml이 dev push에서 cd-ecs-dev.yaml을 호출한다. (workflow_call은 호출한 워크플로의 ref를 sub로 쓴다)
# 배포 job에 GitHub environment를 지정하면 sub가 environment:<이름>으로 바뀌므로 함께 수정한다.
variable "backend_ecs_deploy_github_subjects" {
  description = "GitHub OIDC subjects allowed to deploy the backend service to ECS"
  type        = list(string)
  default = [
    "repo:100-hours-a-week@167328634/KTB4-11th-BE@1352977792:ref:refs/heads/dev",
  ]
}
