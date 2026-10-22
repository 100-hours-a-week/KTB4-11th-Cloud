data "aws_caller_identity" "ai_environment" {}

data "aws_partition" "ai_environment" {}

locals {
  ai_environment_parameter_arn = "arn:${data.aws_partition.ai_environment.partition}:ssm:${var.aws_region}:${data.aws_caller_identity.ai_environment.account_id}:parameter/stockspoon/ai/prod"
  ai_other_environment_arn     = "arn:${data.aws_partition.ai_environment.partition}:ssm:${var.aws_region}:${data.aws_caller_identity.ai_environment.account_id}:parameter/stockspoon/ai/dev"
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
  name   = "stockspoon-v1-ai-environment"
  role   = aws_iam_role.ai_ec2.id
  policy = data.aws_iam_policy_document.ai_environment.json
}
