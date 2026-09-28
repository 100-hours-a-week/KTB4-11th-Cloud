data "aws_caller_identity" "monitoring" {}

data "aws_partition" "monitoring" {}

locals {
  app_cloudwatch_namespace       = "CWAgent"
  app_system_log_group_name      = "/stockspoon/app/system"
  app_system_log_group_arn       = "arn:${data.aws_partition.monitoring.partition}:logs:${var.aws_region}:${data.aws_caller_identity.monitoring.account_id}:log-group:${local.app_system_log_group_name}"
  app_system_log_stream_arn_glob = "${local.app_system_log_group_arn}:log-stream:*"
}

resource "aws_cloudwatch_log_group" "app_system" {
  name              = local.app_system_log_group_name
  retention_in_days = 14

  tags = {
    Name        = "stockspoon-v1-app-system-logs"
    Project     = "stockspoon"
    Environment = "v1"
    ManagedBy   = "Terraform"
  }
}

data "aws_iam_policy_document" "app_cloudwatch_agent_assume_role" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "app_cloudwatch_agent" {
  name               = "stockspoon-v1-app-cloudwatch-agent-role"
  assume_role_policy = data.aws_iam_policy_document.app_cloudwatch_agent_assume_role.json

  tags = {
    Name        = "stockspoon-v1-app-cloudwatch-agent-role"
    Project     = "stockspoon"
    Environment = "v1"
    ManagedBy   = "Terraform"
  }
}

data "aws_iam_policy_document" "app_cloudwatch_agent" {
  statement {
    sid       = "PublishCWAgentMetrics"
    effect    = "Allow"
    actions   = ["cloudwatch:PutMetricData"]
    resources = ["*"]

    condition {
      test     = "StringEquals"
      variable = "cloudwatch:namespace"
      values   = [local.app_cloudwatch_namespace]
    }
  }

  statement {
    sid       = "DescribeLogGroups"
    effect    = "Allow"
    actions   = ["logs:DescribeLogGroups"]
    resources = ["*"]
  }

  statement {
    sid       = "DescribeAppSystemLogStreams"
    effect    = "Allow"
    actions   = ["logs:DescribeLogStreams"]
    resources = [local.app_system_log_group_arn]
  }

  statement {
    sid    = "PublishAppSystemLogs"
    effect = "Allow"
    actions = [
      "logs:CreateLogStream",
      "logs:PutLogEvents",
    ]
    resources = [local.app_system_log_stream_arn_glob]
  }
}

resource "aws_iam_role_policy" "app_cloudwatch_agent" {
  name   = "stockspoon-v1-app-cloudwatch-agent-policy"
  role   = aws_iam_role.app_cloudwatch_agent.id
  policy = data.aws_iam_policy_document.app_cloudwatch_agent.json
}

resource "aws_iam_instance_profile" "app_cloudwatch_agent" {
  name = "stockspoon-v1-app-cloudwatch-agent-profile"
  role = aws_iam_role.app_cloudwatch_agent.name

  tags = {
    Name        = "stockspoon-v1-app-cloudwatch-agent-profile"
    Project     = "stockspoon"
    Environment = "v1"
    ManagedBy   = "Terraform"
  }
}
