locals {
  name_prefix = "${var.project_name}-v2-${var.environment}-valkey"

  backend_user_id = "${local.name_prefix}-backend"
  user_group_id   = "${local.name_prefix}-apps"

  # Key와 Pub/Sub 채널 범위는 애플리케이션 Naming Convention에 맞춰 제한합니다.
  # Cluster client가 토폴로지를 조회할 수 있도록 필요한 읽기 전용 subcommand를 허용합니다.
  backend_access_string = join(" ", [
    "on",
    "~quote:*",
    "~session:*",
    "~token:*",
    "&quotes:*",
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
