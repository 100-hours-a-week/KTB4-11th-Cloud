resource "aws_elasticache_serverless_cache" "valkey" {
  name                 = local.name_prefix
  description          = "StockSpoon V2 development Valkey serverless cache"
  engine               = "valkey"
  major_engine_version = var.valkey_major_engine_version
  network_type         = "ipv4"

  subnet_ids         = data.terraform_remote_state.test.outputs.private_subnet_ids
  security_group_ids = [aws_security_group.valkey.id]
  user_group_id      = aws_elasticache_user_group.applications.user_group_id

  snapshot_retention_limit = 0

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
