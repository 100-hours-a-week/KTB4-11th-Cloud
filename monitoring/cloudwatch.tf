locals {
  ecs_performance_log_arn = "arn:${local.partition}:logs:${var.aws_region}:${local.account_id}:log-group:/aws/ecs/containerinsights/${var.name_prefix}-cluster/performance"
}

resource "aws_iam_role_policy" "telemetry_cloudwatch" {
  count = var.plg_tempo_enabled ? 1 : 0
  name  = "telemetry-cloudwatch-read"
  role  = aws_iam_role.telemetry[0].id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid      = "ReadMetricsAndQueryStatus"
        Effect   = "Allow"
        Action   = ["cloudwatch:ListMetrics", "cloudwatch:GetMetricData", "logs:DescribeLogGroups", "logs:GetQueryResults", "logs:StopQuery"]
        Resource = "*"
        Condition = {
          StringEquals = { "aws:RequestedRegion" = var.aws_region }
        }
      },
      {
        # CloudFront metrics exist only in us-east-1; keep logs access regional.
        Sid      = "ReadCloudFrontMetrics"
        Effect   = "Allow"
        Action   = ["cloudwatch:ListMetrics", "cloudwatch:GetMetricData"]
        Resource = "*"
        Condition = {
          StringEquals = { "aws:RequestedRegion" = "us-east-1" }
        }
      },
      {
        Sid      = "QueryEcsPerformanceOnly"
        Effect   = "Allow"
        Action   = ["logs:StartQuery", "logs:GetLogGroupFields"]
        Resource = [local.ecs_performance_log_arn, "${local.ecs_performance_log_arn}:*"]
      }
    ]
  })
}
