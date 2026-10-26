variable "market_observability_enabled" {
  type        = bool
  default     = false
  description = "Grant read-only ECS metadata access before opting into market Prometheus dashboards/alerts. Does not disable shared CloudWatch collection."
}

resource "aws_iam_role_policy" "market_observability" {
  count = var.plg_tempo_enabled && var.market_observability_enabled ? 1 : 0
  name  = "market-ecs-metadata-read"
  role  = aws_iam_role.telemetry[0].id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = ["ecs:DescribeServices"]
        Resource = "arn:${local.partition}:ecs:${var.aws_region}:${local.account_id}:service/${var.name_prefix}-cluster/${var.name_prefix}-market-http"
      },
      {
        Effect   = "Allow"
        Action   = ["ecs:DescribeTasks"]
        Resource = "arn:${local.partition}:ecs:${var.aws_region}:${local.account_id}:task/${var.name_prefix}-cluster/*"
      },
      {
        Effect   = "Allow"
        Action   = ["ecs:ListTasks"]
        Resource = "*"
        Condition = {
          ArnEquals = { "ecs:cluster" = "arn:${local.partition}:ecs:${var.aws_region}:${local.account_id}:cluster/${var.name_prefix}-cluster" }
        }
      }
    ]
  })
}
