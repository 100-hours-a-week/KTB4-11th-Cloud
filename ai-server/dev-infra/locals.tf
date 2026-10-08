locals {
  name_prefix = "stockspoon-v2-dev-ai"

  common_tags = {
    Project     = "stockspoon"
    Service     = "ai"
    Environment = "dev"
    ManagedBy   = "Terraform"
  }

  ai_cloudwatch_namespace = "AI_DEV_CWAgent"

  ai_log_groups = {
    system = {
      name              = "/stockspoon/v2/dev/ai/system"
      retention_in_days = 14
    }
    application = {
      name              = "/stockspoon/v2/dev/ai/application"
      retention_in_days = 30
    }
    postgres = {
      name              = "/stockspoon/v2/dev/ai/postgres"
      retention_in_days = 30
    }
    questdb = {
      name              = "/stockspoon/v2/dev/ai/questdb"
      retention_in_days = 30
    }
  }
}
