data "aws_iam_policy_document" "ec2_assume_role" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
  }
}

data "aws_iam_policy_document" "k6_cloudwatch" {
  statement {
    sid       = "DescribeLogGroups"
    effect    = "Allow"
    actions   = ["logs:DescribeLogGroups"]
    resources = ["*"]
  }

  statement {
    sid       = "DescribeTestSystemLogStreams"
    effect    = "Allow"
    actions   = ["logs:DescribeLogStreams"]
    resources = [local.test_system_log_group_arn]
  }

  statement {
    sid    = "PublishTestSystemLogs"
    effect = "Allow"
    actions = [
      "logs:CreateLogStream",
      "logs:PutLogEvents",
    ]
    resources = ["${local.test_system_log_group_arn}:log-stream:*"]
  }

  statement {
    sid       = "PublishCWAgentMetrics"
    effect    = "Allow"
    actions   = ["cloudwatch:PutMetricData"]
    resources = ["*"]

    condition {
      test     = "StringEquals"
      variable = "cloudwatch:namespace"
      values   = ["CWAgent"]
    }
  }
}

resource "aws_iam_role" "sse_k6" {
  name               = "${var.name_prefix}-sse-k6-ec2-role"
  assume_role_policy = data.aws_iam_policy_document.ec2_assume_role.json

  tags = {
    Name        = "${var.name_prefix}-sse-k6-ec2-role"
    Project     = "stockspoon"
    Environment = "loadtest"
    ManagedBy   = "Terraform"
  }
}

resource "aws_iam_role_policy_attachment" "sse_k6_ssm" {
  role       = aws_iam_role.sse_k6.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_role_policy" "sse_k6_cloudwatch" {
  name   = "${var.name_prefix}-sse-k6-cloudwatch-policy"
  role   = aws_iam_role.sse_k6.id
  policy = data.aws_iam_policy_document.k6_cloudwatch.json
}

resource "aws_iam_instance_profile" "sse_k6" {
  name = "${var.name_prefix}-sse-k6-instance-profile"
  role = aws_iam_role.sse_k6.name

  tags = {
    Name        = "${var.name_prefix}-sse-k6-instance-profile"
    Project     = "stockspoon"
    Environment = "loadtest"
    ManagedBy   = "Terraform"
  }
}

locals {
  test_system_log_group_arn = "arn:${data.aws_partition.current.partition}:logs:${var.aws_region}:${data.aws_caller_identity.current.account_id}:log-group:/stockspoon/loadtest/system"
}
