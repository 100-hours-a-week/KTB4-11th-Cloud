variable "api_waf_enabled" {
  # 활성 여부와 별개로 실제 차단은 api_waf_mode로 제어한다.
  # Count에서도 요청당 WAF 요금과 요청별 로그가 발생한다.
  description = "Attach managed WAF protections and a per-IP API rate rule to CloudFront."
  type        = bool
  default     = true
  validation {
    condition     = !var.api_waf_enabled || var.frontend_edge_enabled
    error_message = "API WAF requires frontend_edge_enabled; it counts viewer IPs at CloudFront, not proxy IPs at ALB."
  }
}

variable "api_waf_mode" {
  # This mode controls only api-per-source-ip. Managed SQLi and Linux rules
  # keep their AWS-managed blocking actions in either mode.
  # tfvars/TF_VAR settings override this default; verify the deployed ACL separately.
  type    = string
  default = "count"
  validation {
    condition     = contains(["count", "block"], var.api_waf_mode)
    error_message = "api_waf_mode must be count or block."
  }
}

variable "api_waf_request_limit" {
  description = "Per-source-IP /api/ rate-rule limit; default 7000 requests within a 300-second Count window."
  type        = number
  default     = 7000
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
  description = "CloudFront WAF policy, managed rule modes, API rate limit, and us-east-1 logs."
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
