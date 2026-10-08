resource "aws_cloudwatch_log_group" "ai" {
  for_each = local.ai_log_groups

  name              = each.value.name
  retention_in_days = each.value.retention_in_days

  tags = {
    Name = "${local.name_prefix}-${each.key}-logs"
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
  name   = "${local.name_prefix}-cloudwatch"
  policy = data.aws_iam_policy_document.ai_cloudwatch.json

  tags = {
    Name = "${local.name_prefix}-cloudwatch"
  }
}

resource "aws_iam_role_policy_attachment" "ai_cloudwatch" {
  role       = aws_iam_role.ai_ec2.name
  policy_arn = aws_iam_policy.ai_cloudwatch.arn
}
