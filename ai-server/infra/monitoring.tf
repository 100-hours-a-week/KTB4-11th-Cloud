locals {
  ai_cloudwatch_namespace = "AI_CWAgent"

  ai_log_groups = {
    system = {
      name              = "/stockspoon/ai/system"
      retention_in_days = 14
    }
    application = {
      name              = "/stockspoon/ai/application"
      retention_in_days = 30
    }
    postgres = {
      name              = "/stockspoon/ai/postgres"
      retention_in_days = 30
    }
    questdb = {
      name              = "/stockspoon/ai/questdb"
      retention_in_days = 30
    }
  }
}

resource "aws_cloudwatch_log_group" "ai" {
  for_each = local.ai_log_groups

  name              = each.value.name
  retention_in_days = each.value.retention_in_days

  tags = {
    Name        = "stockspoon-v1-ai-${each.key}-logs"
    Project     = "stockspoon"
    Environment = "v1"
    ManagedBy   = "Terraform"
  }
}

data "aws_iam_policy_document" "ai_cloudwatch" {
  statement {
    sid       = "PublishAIMetrics"
    effect    = "Allow"
    actions   = ["cloudwatch:PutMetricData"]
    resources = ["*"]

    condition {
      test     = "StringEquals"
      variable = "cloudwatch:namespace"
      values   = [local.ai_cloudwatch_namespace]
    }
  }

  statement {
    sid       = "DescribeAILogGroups"
    effect    = "Allow"
    actions   = ["logs:DescribeLogGroups"]
    resources = ["*"]
  }

  statement {
    sid       = "DescribeAILogStreams"
    effect    = "Allow"
    actions   = ["logs:DescribeLogStreams"]
    resources = [for log_group in aws_cloudwatch_log_group.ai : log_group.arn]
  }

  statement {
    sid    = "PublishAILogs"
    effect = "Allow"
    actions = [
      "logs:CreateLogStream",
      "logs:PutLogEvents",
    ]
    resources = [for log_group in aws_cloudwatch_log_group.ai : "${log_group.arn}:log-stream:*"]
  }
}

resource "aws_iam_policy" "ai_cloudwatch" {
  name   = "stockspoon-v1-ai-cloudwatch-policy"
  policy = data.aws_iam_policy_document.ai_cloudwatch.json

  tags = {
    Name        = "stockspoon-v1-ai-cloudwatch-policy"
    Project     = "stockspoon"
    Environment = "v1"
    ManagedBy   = "Terraform"
  }
}

resource "aws_iam_role_policy_attachment" "ai_cloudwatch" {
  role       = aws_iam_role.ai_ec2.name
  policy_arn = aws_iam_policy.ai_cloudwatch.arn
}
