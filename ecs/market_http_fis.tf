resource "aws_iam_role" "market_http_fis_managed" {
  count = local.ai_market_enabled ? 1 : 0

  name = "${var.name_prefix}-market-http-fis-ssm"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "ssm.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy_attachment" "market_http_fis_managed_core" {
  count = local.ai_market_enabled ? 1 : 0

  role       = aws_iam_role.market_http_fis_managed[0].name
  policy_arn = "arn:${local.partition}:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_role_policy" "market_http_fis_cleanup" {
  count = local.ai_market_enabled ? 1 : 0

  name = "market-http-fis-registration-cleanup"
  role = aws_iam_role.market_http_fis_managed[0].id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      { Effect = "Allow", Action = "ssm:DeleteActivation", Resource = "*" },
      {
        Effect    = "Allow"
        Action    = "ssm:DeregisterManagedInstance"
        Resource  = "arn:${local.partition}:ssm:${var.aws_region}:${local.account_id}:managed-instance/*"
        Condition = { StringEquals = { "ssm:resourceTag/FAULT_INJECTION_SIDECAR" = "true" } }
      }
    ]
  })
}

resource "aws_iam_role_policy" "market_http_fis_registration" {
  count = local.ai_market_enabled ? 1 : 0

  name = "market-http-fis-registration"
  role = aws_iam_role.market_http_task.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = ["ssm:CreateActivation", "ssm:AddTagsToResource"]
        Resource = "*"
        Condition = {
          StringEquals = { "aws:RequestTag/FAULT_INJECTION_SIDECAR" = "true" }
          StringLike   = { "aws:RequestTag/ECS_TASK_ARN" = "arn:${local.partition}:ecs:${var.aws_region}:${local.account_id}:task/${aws_ecs_cluster.main.name}/*" }
        }
      },
      {
        Effect    = "Allow"
        Action    = "iam:PassRole"
        Resource  = aws_iam_role.market_http_fis_managed[0].arn
        Condition = { StringEquals = { "iam:PassedToService" = "ssm.amazonaws.com" } }
      }
    ]
  })
}

output "market_http_fis_managed_role_name" {
  value = try(aws_iam_role.market_http_fis_managed[0].name, null)
}
