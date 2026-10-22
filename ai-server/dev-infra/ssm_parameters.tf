locals {
  ai_secret_parameter_keys = toset([
    "POSTGRES_PASSWORD",
    "QUESTDB_PASSWORD",
    "NEWS_PREPROCESSOR_DART_API_KEY",
    "NEWS_GRAPH_BUILDER_LLM_API_KEY",
    "MARKET_SYNCER_KIWOOM_APP_KEY",
    "MARKET_SYNCER_KIWOOM_SECRET_KEY",
    "MARKET_SYNCER_DART_API_KEY",
    "MARKET_STREAMER_KIWOOM_APP_KEY",
    "MARKET_STREAMER_KIWOOM_SECRET_KEY",
    "MARKET_COLLECTOR_KIWOOM_APP_KEY",
    "MARKET_COLLECTOR_KIWOOM_SECRET_KEY",
    "PORTFOLIO_BUILDER_LLM_API_KEY",
    "PORTFOLIO_REBALANCER_BACKEND_JWT_SECRET",
  ])
}

resource "aws_ssm_parameter" "ai_secret" {
  for_each = local.ai_secret_parameter_keys

  name             = "/stockspoon/ai/dev/${each.key}"
  description      = "AI dev secret: ${each.key}. Replace the initial placeholder before deployment."
  type             = "SecureString"
  tier             = "Standard"
  value_wo         = "__SET_ME_BEFORE_DEPLOY__"
  value_wo_version = 1

  lifecycle {
    ignore_changes  = all
    prevent_destroy = true
  }
}
