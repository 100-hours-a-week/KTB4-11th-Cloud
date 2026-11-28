# The observer reads existing logs; no DB credentials or failover control access.
resource "aws_iam_role_policy" "telemetry_db_fis" {
  count = var.plg_tempo_enabled ? 1 : 0
  name  = "telemetry-db-fis-repman-logs-read"
  role  = aws_iam_role.telemetry[0].id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = ["logs:FilterLogEvents"]
      Resource = "arn:${local.partition}:logs:${var.aws_region}:${local.account_id}:log-group:/ecs/${var.name_prefix}/repman:*"
    }]
  })
}
