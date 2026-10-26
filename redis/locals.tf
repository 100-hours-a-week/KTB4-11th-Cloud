locals {
  name_prefix = "${var.project_name}-v2-${var.environment}-valkey"

  is_dev = var.environment == "dev"
  # 리소스 설명에 쓰는 환경 이름입니다. dev 값은 기존 리소스 설명과 같아야 교체되지 않습니다.
  environment_label = local.is_dev ? "development" : "production"

  # dev는 test-infra VPC, prod는 ECS와 같은 shared-infra VPC를 사용합니다.
  vpc_id             = local.is_dev ? one(data.terraform_remote_state.test[*].outputs.vpc_id) : one(data.terraform_remote_state.shared[*].outputs.vpc_id)
  private_subnet_ids = local.is_dev ? one(data.terraform_remote_state.test[*].outputs.private_subnet_ids) : one(data.terraform_remote_state.shared[*].outputs.private_subnet_ids)

  # 개발 서버 접근 허용 대상입니다. prod에서는 null이며 접근 허용은 ecs root가 관리합니다.
  backend_security_group_id = try(data.terraform_remote_state.test[0].outputs.dev_app_security_group_id, null)
  backend_iam_role_name     = try(data.terraform_remote_state.test[0].outputs.dev_app_iam_role_name, null)

  ai_security_group_id = try(data.terraform_remote_state.ai_dev[0].outputs.ai_security_group_id, null)
  ai_iam_role_name     = try(basename(data.terraform_remote_state.ai_dev[0].outputs.ai_iam_role_arn), null)

  # dev: Backend·AI가 공용 사용자 하나(backend)를 사용합니다. 기존 연결을 끊지 않도록 이름을 유지합니다.
  # prod: ECS 서비스마다 사용자와 Connect Policy를 분리해 서비스별로 자기 사용자로만 접속하게 합니다.
  #       ai는 V1 AI 운영 EC2(market-collector·market-streamer 등)용 사용자이며,
  #       SG ingress와 Role 연결은 ai-server/infra root가 이 root의 Output을 참조해 관리합니다.
  app_services = local.is_dev ? ["backend"] : ["backend", "socket", "market-data", "match-engine", "ai"]

  app_users = {
    for service in local.app_services : service => {
      user_id       = "${local.name_prefix}-${service}"
      access_string = local.is_dev ? local.dev_access_string : local.prod_access_string
    }
  }

  user_group_id = "${local.name_prefix}-apps"

  alarm_prefix                  = local.name_prefix
  discord_notifier_name         = "${local.name_prefix}-discord-notifier"
  discord_webhook_secret_name   = "${var.project_name}/v2/${var.environment}/valkey/discord-webhook"
  storage_alarm_threshold_bytes = var.valkey_max_data_storage_gb * 1024 * 1024 * 1024 * 0.75
  ecpu_alarm_threshold_per_min  = var.valkey_max_ecpu_per_second * 60 * 0.75

  # 모든 Key·채널과 일반 명령을 허용하되 운영에 위험한 명령(-@dangerous: FLUSHALL, KEYS, CONFIG 등)은 차단합니다.
  # dev는 Backend와 AI가 같은 사용자를 사용합니다.
  # prod도 V2 시세 계약(AI market-streamer·market-http의 price:{code} Key·채널)이 확정되는 동안
  # dev와 같은 범위를 사용하고, 서비스별 사용자·Connect Policy로 접속 주체만 분리합니다.
  # TODO: 서비스별 Key·채널 사용이 확정되면 서비스별 access_string으로 범위를 좁힙니다.
  # `&*`가 모든 채널을 허용하므로 `resetchannels`는 넣지 않습니다.
  # ElastiCache가 의미 없는 `resetchannels`를 제거한 형태로 저장해 plan에 영구 diff가 생기기 때문입니다.
  dev_access_string = join(" ", [
    "on",
    "~*",
    "&*",
    "+@all",
    "-@dangerous",
  ])

  prod_access_string = local.dev_access_string

  common_tags = {
    Project     = var.project_name
    Service     = "valkey"
    Environment = var.environment
    ManagedBy   = "Terraform"
  }
}
