# AI market-http가 사용하는 값
locals {
  # AI CI가 push하는 통합 이미지. 서비스는 command로 진입점을 고른다. (운영 Compose와 같은 산출물)
  ai_image          = "${data.terraform_remote_state.app.outputs.public_ecr_ai_repository_uri}:${var.ai_image_tag}"
  ai_market_enabled = var.ai_image_tag != ""

  # V1 AI 운영 서버의 QuestDB (Compose가 이 private IP에만 포트를 게시)
  ai_private_ip = data.terraform_remote_state.ai.outputs.ai_private_ip

  valkey_endpoint   = data.terraform_remote_state.redis.outputs.valkey_endpoint_address
  valkey_port       = data.terraform_remote_state.redis.outputs.valkey_endpoint_port
  valkey_cache_name = data.terraform_remote_state.redis.outputs.valkey_cache_name
  valkey_users      = data.terraform_remote_state.redis.outputs.valkey_user_names
  valkey_policies   = data.terraform_remote_state.redis.outputs.valkey_connect_policy_arns

  # Valkey 사용자는 V2 서버 역할 이름을 따른다. (Socket = market-http)
  market_http_valkey_role = "socket"
}
