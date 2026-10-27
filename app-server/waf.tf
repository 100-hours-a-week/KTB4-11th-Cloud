variable "api_waf_enabled" {
  # 활성 여부와 별개로 실제 차단은 api_waf_mode로 제어한다.
  # Count에서도 요청당 WAF 요금과 요청별 로그가 발생한다.
  description = "Attach experimental per-IP API rate rules to the public CloudFront entry point."
  type        = bool
  default     = true
  validation {
    condition     = !var.api_waf_enabled || var.frontend_edge_enabled
    error_message = "API WAF requires frontend_edge_enabled; it counts viewer IPs at CloudFront, not proxy IPs at ALB."
  }
}

variable "api_waf_mode" {
  # 현재는 Count: 기준 초과를 기록하며 요청은 차단하지 않는다.
  # DB 마이그레이션·백엔드 처리 성능 테스트 중에는 "count"를 유지한다.
  # Count는 기준 초과만 기록하며 차단하지 않는다. 방어 테스트 시 "block"으로 복구한다.
  # tfvars/TF_VAR 설정은 이 기본값보다 우선하므로 전환 전 plan과 적용 후 output을 확인한다.
  type    = string
  default = "count"
  validation {
    condition     = contains(["count", "block"], var.api_waf_mode)
    error_message = "api_waf_mode must be count or block."
  }
}

variable "api_waf_request_limit" {
  type    = number
  default = 500
}

variable "api_waf_evaluation_window_sec" {
  type    = number
  default = 300
}

# CloudFront WAF resources and logs must use the us-east-1 provider.
# Protects viewer traffic through CloudFront; direct ALB access is a separate concern.
module "api_waf" {
  count  = var.api_waf_enabled ? 1 : 0
  source = "./modules/api-waf"
  providers = {
    aws = aws.us_east_1
  }
  request_limit         = var.api_waf_request_limit
  evaluation_window_sec = var.api_waf_evaluation_window_sec
  mode                  = var.api_waf_mode
}

output "api_waf" {
  description = "Experimental API policy, CloudFront ACL and us-east-1 logs. Count does not prevent flooding."
  value = var.api_waf_enabled ? {
    web_acl_arn           = module.api_waf[0].web_acl_arn
    log_group_name        = module.api_waf[0].log_group_name
    region                = "us-east-1"
    mode                  = var.api_waf_mode
    request_limit         = var.api_waf_request_limit
    evaluation_window_sec = var.api_waf_evaluation_window_sec
    path_prefix           = "/api/"
  } : null
}
