locals {
  name_prefix = "${var.project_name}-v2-${var.environment}-valkey"

  backend_security_group_id = try(data.terraform_remote_state.test.outputs.dev_app_security_group_id, null)
  backend_iam_role_name     = try(data.terraform_remote_state.test.outputs.dev_app_iam_role_name, null)

  ai_security_group_id = try(data.terraform_remote_state.ai_dev.outputs.ai_security_group_id, null)
  ai_iam_role_name     = try(basename(data.terraform_remote_state.ai_dev.outputs.ai_iam_role_arn), null)

  # 기존 Backend 연결을 끊지 않도록 리소스 이름은 유지하고 AI와 공용으로 사용합니다.
  backend_user_id = "${local.name_prefix}-backend"
  user_group_id   = "${local.name_prefix}-apps"

  alarm_prefix                  = local.name_prefix
  discord_notifier_name         = "${local.name_prefix}-discord-notifier"
  discord_webhook_secret_name   = "${var.project_name}/v2/${var.environment}/valkey/discord-webhook"
  storage_alarm_threshold_bytes = var.valkey_max_data_storage_gb * 1024 * 1024 * 1024 * 0.75
  ecpu_alarm_threshold_per_min  = var.valkey_max_ecpu_per_second * 60 * 0.75

  # 개발 환경에서는 Backend와 AI가 같은 사용자를 사용합니다.
  # 모든 Key·채널과 일반 명령을 허용하되 운영에 위험한 명령은 차단합니다.
  # `&*`가 모든 채널을 허용하므로 `resetchannels`는 넣지 않습니다.
  # ElastiCache가 의미 없는 `resetchannels`를 제거한 형태로 저장해 plan에 영구 diff가 생기기 때문입니다.
  backend_access_string = join(" ", [
    "on",
    "~*",
    "&*",
    "+@all",
    "-@dangerous",
  ])

  common_tags = {
    Project     = var.project_name
    Service     = "valkey"
    Environment = var.environment
    ManagedBy   = "Terraform"
  }
}
