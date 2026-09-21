# GitHub Actions exchanges an OIDC token for short-lived AWS credentials.
resource "aws_iam_openid_connect_provider" "github_actions" {
  url = "https://token.actions.githubusercontent.com"

  client_id_list = [
    "sts.amazonaws.com",
  ]

  tags = {
    Name      = "github-actions-oidc"
    Project   = "stockspoon"
    ManagedBy = "Terraform"
  }
}

data "aws_iam_policy_document" "github_actions_assume_role" {
  statement {
    sid     = "AllowApplicationMainBranches"
    effect  = "Allow"
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = [aws_iam_openid_connect_provider.github_actions.arn]
    }

    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:aud"
      values   = ["sts.amazonaws.com"]
    }

    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:sub"
      values = [
        "repo:${var.github_repository_owner}/${var.github_repository_name}:ref:refs/heads/${var.github_deployment_branch}",
        "repo:${var.github_repository_owner}/${var.github_repository_name}:ref:refs/heads/dev",
        "repo:${var.github_repository_owner}/${var.github_frontend_repository_name}:ref:refs/heads/${var.github_deployment_branch}",
        "repo:${var.github_repository_owner}/${var.github_ai_repository_name}:ref:refs/heads/${var.github_deployment_branch}",
        "repo:${var.github_repository_owner}/${var.github_repository_name}:environment:production",
        "repo:${var.github_repository_owner}/${var.github_frontend_repository_name}:environment:production",
        "repo:${var.github_repository_owner}/${var.github_ai_repository_name}:environment:production",
      ]
    }
  }
}

resource "aws_iam_role" "github_actions_ecr_push" {
  name               = "stockspoon-v1-github-actions-ecr-push"
  assume_role_policy = data.aws_iam_policy_document.github_actions_assume_role.json

  tags = {
    Name        = "stockspoon-v1-github-actions-ecr-push"
    Project     = "stockspoon"
    Environment = "v1"
    ManagedBy   = "Terraform"
  }
}

data "aws_iam_policy_document" "github_actions_ecr_push" {
  statement {
    sid    = "GetPublicECRAuthorizationToken"
    effect = "Allow"
    actions = [
      "ecr-public:GetAuthorizationToken",
      "sts:GetServiceBearerToken",
    ]
    resources = ["*"]
  }

  statement {
    sid    = "PushApplicationImages"
    effect = "Allow"
    actions = [
      "ecr-public:BatchCheckLayerAvailability",
      "ecr-public:CompleteLayerUpload",
      "ecr-public:DescribeImages",
      "ecr-public:InitiateLayerUpload",
      "ecr-public:PutImage",
      "ecr-public:UploadLayerPart",
    ]
    resources = [
      aws_ecrpublic_repository.backend.arn,
      aws_ecrpublic_repository.frontend.arn,
      aws_ecrpublic_repository.ai.arn,
    ]
  }
}

resource "aws_iam_role_policy" "github_actions_ecr_push" {
  name   = "stockspoon-v1-public-ecr-push"
  role   = aws_iam_role.github_actions_ecr_push.id
  policy = data.aws_iam_policy_document.github_actions_ecr_push.json
}
