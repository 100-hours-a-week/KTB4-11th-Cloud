resource "aws_elasticache_serverless_cache" "valkey" {
  name                 = local.name_prefix
  description          = "StockSpoon V2 ${local.environment_label} Valkey serverless cache"
  engine               = "valkey"
  major_engine_version = var.valkey_major_engine_version
  network_type         = "ipv4"

  subnet_ids         = local.private_subnet_ids
  security_group_ids = [aws_security_group.valkey.id]
  user_group_id      = aws_elasticache_user_group.applications.user_group_id

  # 원본 데이터 없이 재생성 가능한 캐시·리스만 저장하므로 dev는 0, prod는 짧게 보관합니다.
  snapshot_retention_limit = var.valkey_snapshot_retention_limit
  daily_snapshot_time      = var.valkey_daily_snapshot_time

  cache_usage_limits {
    data_storage {
      maximum = var.valkey_max_data_storage_gb
      unit    = "GB"
    }

    ecpu_per_second {
      maximum = var.valkey_max_ecpu_per_second
    }
  }

  tags = {
    Name = local.name_prefix
  }
}
