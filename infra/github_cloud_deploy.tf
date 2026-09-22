# Cloud CD assumes this role only to verify a requested image tag and digest.
data "aws_iam_policy_document" "github_cloud_deploy_assume_role" {
  statement {
    sid     = "AllowCloudProductionEnvironment"
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
        "repo:${var.github_repository_owner}@${var.github_repository_owner_id}/${var.github_cloud_repository_name}@${var.github_cloud_repository_id}:environment:production",
      ]
    }
  }
}

resource "aws_iam_role" "github_cloud_deploy" {
  name               = "stockspoon-v1-github-cloud-deploy"
  assume_role_policy = data.aws_iam_policy_document.github_cloud_deploy_assume_role.json

  tags = {
    Name        = "stockspoon-v1-github-cloud-deploy"
    Project     = "stockspoon"
    Environment = "v1"
    ManagedBy   = "Terraform"
  }
}

data "aws_iam_policy_document" "github_cloud_deploy" {
  statement {
    sid     = "DescribeDeploymentImages"
    effect  = "Allow"
    actions = ["ecr-public:DescribeImages"]
    resources = [
      aws_ecrpublic_repository.backend.arn,
      aws_ecrpublic_repository.frontend.arn,
    ]
  }
}

resource "aws_iam_role_policy" "github_cloud_deploy" {
  name   = "stockspoon-v1-public-ecr-describe"
  role   = aws_iam_role.github_cloud_deploy.id
  policy = data.aws_iam_policy_document.github_cloud_deploy.json
}
