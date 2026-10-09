locals {
  name_prefix = "${var.project_name}-v2-${var.environment}-valkey"

  backend_user_id = "${local.name_prefix}-backend"
  user_group_id   = "${local.name_prefix}-apps"

  alarm_prefix                  = local.name_prefix
  discord_notifier_name         = "${local.name_prefix}-discord-notifier"
  discord_webhook_secret_name   = "${var.project_name}/v2/${var.environment}/valkey/discord-webhook"
  storage_alarm_threshold_bytes = var.valkey_max_data_storage_gb * 1024 * 1024 * 1024 * 0.75
  ecpu_alarm_threshold_per_min  = var.valkey_max_ecpu_per_second * 60 * 0.75

  # Key와 Pub/Sub 채널 범위는 애플리케이션 Naming Convention에 맞춰 제한합니다.
  # Cluster client가 토폴로지를 조회할 수 있도록 필요한 읽기 전용 subcommand를 허용합니다.
  backend_access_string = join(" ", [
    "on",
    "~quote:*",
    "~session:*",
    "~token:*",
    "resetchannels",
    "&quotes:*",
    "-@all",
    "+@read",
    "+@write",
    "+@pubsub",
    "+@connection",
    "-@dangerous",
    "+cluster|slots",
    "+cluster|shards",
    "+cluster|nodes",
  ])

  common_tags = {
    Project     = var.project_name
    Service     = "valkey"
    Environment = var.environment
    ManagedBy   = "Terraform"
  }
}
