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

resource "aws_iam_role" "app" {
  name               = "${var.name_prefix}-app-ec2-role"
  assume_role_policy = data.aws_iam_policy_document.ec2_assume_role.json

  tags = {
    Name        = "${var.name_prefix}-app-ec2-role"
    Project     = "stockspoon"
    Environment = "loadtest"
    ManagedBy   = "Terraform"
  }
}

resource "aws_iam_role_policy_attachment" "app_ssm" {
  role       = aws_iam_role.app.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

data "aws_caller_identity" "current" {}

data "aws_partition" "current" {}

locals {
  app_log_group_names = [
    "/stockspoon/app/system",
    local.test_system_log_group_name,
    "/stockspoon/app/containers",
    "/stockspoon/app/containers/nginx",
    "/stockspoon/app/containers/frontend",
    "/stockspoon/app/containers/backend",
    "/stockspoon/app/containers/db",
  ]

  app_log_group_arns = [
    for name in local.app_log_group_names :
    "arn:${data.aws_partition.current.partition}:logs:${var.aws_region}:${data.aws_caller_identity.current.account_id}:log-group:${name}"
  ]
}

data "aws_iam_policy_document" "app_cloudwatch" {
  statement {
    sid       = "DescribeLogGroups"
    effect    = "Allow"
    actions   = ["logs:DescribeLogGroups"]
    resources = ["*"]
  }

  statement {
    sid       = "DescribeAppLogStreams"
    effect    = "Allow"
    actions   = ["logs:DescribeLogStreams"]
    resources = local.app_log_group_arns
  }

  statement {
    sid    = "PublishAppLogs"
    effect = "Allow"
    actions = [
      "logs:CreateLogStream",
      "logs:PutLogEvents",
    ]
    resources = [for arn in local.app_log_group_arns : "${arn}:log-stream:*"]
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

resource "aws_iam_role_policy" "app_cloudwatch" {
  name   = "${var.name_prefix}-app-cloudwatch-policy"
  role   = aws_iam_role.app.id
  policy = data.aws_iam_policy_document.app_cloudwatch.json
}

resource "aws_iam_instance_profile" "app" {
  name = "${var.name_prefix}-app-instance-profile"
  role = aws_iam_role.app.name

  tags = {
    Name        = "${var.name_prefix}-app-instance-profile"
    Project     = "stockspoon"
    Environment = "loadtest"
    ManagedBy   = "Terraform"
  }
}

resource "aws_iam_role" "k6" {
  name               = "${var.name_prefix}-k6-ec2-role"
  assume_role_policy = data.aws_iam_policy_document.ec2_assume_role.json

  tags = {
    Name        = "${var.name_prefix}-k6-ec2-role"
    Project     = "stockspoon"
    Environment = "loadtest"
    ManagedBy   = "Terraform"
  }
}

resource "aws_iam_role_policy_attachment" "k6_ssm" {
  role       = aws_iam_role.k6.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
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

resource "aws_iam_role_policy" "k6_cloudwatch" {
  name   = "${var.name_prefix}-k6-cloudwatch-policy"
  role   = aws_iam_role.k6.id
  policy = data.aws_iam_policy_document.k6_cloudwatch.json
}

resource "aws_iam_instance_profile" "k6" {
  name = "${var.name_prefix}-k6-instance-profile"
  role = aws_iam_role.k6.name

  tags = {
    Name        = "${var.name_prefix}-k6-instance-profile"
    Project     = "stockspoon"
    Environment = "loadtest"
    ManagedBy   = "Terraform"
  }
}
