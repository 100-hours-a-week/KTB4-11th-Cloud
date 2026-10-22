locals {
  ai_environment_parameter_arn = "arn:${data.aws_partition.current.partition}:ssm:${var.aws_region}:${data.aws_caller_identity.current.account_id}:parameter/stockspoon/ai/dev"
  ai_other_environment_arn     = "arn:${data.aws_partition.current.partition}:ssm:${var.aws_region}:${data.aws_caller_identity.current.account_id}:parameter/stockspoon/ai/prod"
}

data "aws_iam_policy_document" "ai_environment" {
  statement {
    sid     = "ReadApplicationEnvironment"
    effect  = "Allow"
    actions = ["ssm:GetParameter", "ssm:GetParameters"]
    resources = [
      local.ai_environment_parameter_arn,
      "${local.ai_environment_parameter_arn}/*",
    ]
  }

  statement {
    sid     = "DenyOtherApplicationEnvironment"
    effect  = "Deny"
    actions = ["ssm:GetParameter*"]
    resources = [
      local.ai_other_environment_arn,
      "${local.ai_other_environment_arn}/*",
    ]
  }

  statement {
    sid       = "DenyEnvironmentPathTraversal"
    effect    = "Deny"
    actions   = ["ssm:GetParametersByPath"]
    resources = ["*"]
  }
}

resource "aws_iam_role_policy" "ai_environment" {
  name   = "${local.name_prefix}-environment"
  role   = aws_iam_role.ai_ec2.id
  policy = data.aws_iam_policy_document.ai_environment.json
}
