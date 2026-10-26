# Separate GitHub Actions roles keep infrastructure access independent from the
# existing ECR image-push role. The plan role can read Terraform-managed AWS
# resources and state, while the apply role can update the resources managed by
# this repository.

data "aws_iam_policy_document" "github_actions_terraform_plan_assume_role" {
  statement {
    sid     = "AllowCloudRepositoryPullRequests"
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
        "repo:100-hours-a-week@167328634/KTB4-11th-Cloud@1350512544:pull_request",
        "repo:100-hours-a-week@167328634/KTB4-11th-Cloud@1350512544:ref:refs/heads/main",
      ]
    }
  }
}

data "aws_iam_policy_document" "github_actions_terraform_apply_assume_role" {
  statement {
    sid     = "AllowMainBranchTerraformApply"
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
        "repo:100-hours-a-week@167328634/KTB4-11th-Cloud@1350512544:ref:refs/heads/main",
      ]
    }
  }
}

resource "aws_iam_role" "github_actions_terraform_plan" {
  name                 = "stockspoon-v1-github-actions-terraform-plan"
  assume_role_policy   = data.aws_iam_policy_document.github_actions_terraform_plan_assume_role.json
  max_session_duration = 3600

  tags = {
    Name        = "stockspoon-v1-github-actions-terraform-plan"
    Project     = "stockspoon"
    Environment = "v1"
    ManagedBy   = "Terraform"
  }
}

resource "aws_iam_role_policy_attachment" "github_actions_terraform_plan_read" {
  role       = aws_iam_role.github_actions_terraform_plan.name
  policy_arn = aws_iam_policy.github_actions_terraform_read.arn
}

resource "aws_iam_role_policy_attachment" "github_actions_terraform_plan_state_access" {
  role       = aws_iam_role.github_actions_terraform_plan.name
  policy_arn = aws_iam_policy.github_actions_terraform_state_access.arn
}

resource "aws_iam_role" "github_actions_terraform_apply" {
  name                 = "stockspoon-v1-github-actions-terraform-apply"
  assume_role_policy   = data.aws_iam_policy_document.github_actions_terraform_apply_assume_role.json
  max_session_duration = 3600

  tags = {
    Name        = "stockspoon-v1-github-actions-terraform-apply"
    Project     = "stockspoon"
    Environment = "v1"
    ManagedBy   = "Terraform"
  }
}

resource "aws_iam_role_policy_attachment" "github_actions_terraform_apply_read" {
  role       = aws_iam_role.github_actions_terraform_apply.name
  policy_arn = aws_iam_policy.github_actions_terraform_read.arn
}

resource "aws_iam_role_policy_attachment" "github_actions_terraform_apply_state_access" {
  role       = aws_iam_role.github_actions_terraform_apply.name
  policy_arn = aws_iam_policy.github_actions_terraform_state_access.arn
}

output "github_actions_terraform_plan_role_arn" {
  description = "AWS role ARN to set as the GitHub Actions repository variable AWS_TERRAFORM_PLAN_ROLE_ARN"
  value       = aws_iam_role.github_actions_terraform_plan.arn
}

output "github_actions_terraform_apply_role_arn" {
  description = "AWS role ARN to set as the GitHub Actions repository variable AWS_TERRAFORM_APPLY_ROLE_ARN"
  value       = aws_iam_role.github_actions_terraform_apply.arn
}
