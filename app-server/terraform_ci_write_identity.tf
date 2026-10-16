data "aws_iam_policy_document" "terraform_ci_write_identity" {
  statement {
    sid    = "ManageTerraformServiceRolesAndPolicies"
    effect = "Allow"
    actions = [
      "iam:AddRoleToInstanceProfile",
      "iam:AttachRolePolicy",
      "iam:CreateInstanceProfile",
      "iam:CreatePolicy",
      "iam:CreatePolicyVersion",
      "iam:CreateRole",
      "iam:DeleteInstanceProfile",
      "iam:DeletePolicy",
      "iam:DeletePolicyVersion",
      "iam:DeleteRole",
      "iam:DeleteRolePolicy",
      "iam:DetachRolePolicy",
      "iam:PutRolePolicy",
      "iam:RemoveRoleFromInstanceProfile",
      "iam:SetDefaultPolicyVersion",
      "iam:TagInstanceProfile",
      "iam:TagPolicy",
      "iam:TagRole",
      "iam:UntagInstanceProfile",
      "iam:UntagPolicy",
      "iam:UntagRole",
      "iam:UpdateAssumeRolePolicy",
      "iam:UpdateRole",
      "iam:UpdateRoleDescription",
    ]
    resources = local.github_actions_terraform_iam_resource_arns
  }

  statement {
    sid    = "ManageExistingAccountUsersAndGroups"
    effect = "Allow"
    actions = [
      "iam:AddUserToGroup",
      "iam:AttachGroupPolicy",
      "iam:AttachUserPolicy",
      "iam:CreateGroup",
      "iam:CreateUser",
      "iam:DeleteGroup",
      "iam:DeleteGroupPolicy",
      "iam:DeleteUser",
      "iam:DetachGroupPolicy",
      "iam:DetachUserPolicy",
      "iam:PutGroupPolicy",
      "iam:RemoveUserFromGroup",
      "iam:TagUser",
      "iam:UntagUser",
      "iam:UpdateGroup",
      "iam:UpdateUser",
    ]
    resources = local.github_actions_terraform_account_iam_arns
  }

  statement {
    sid       = "PassStockspoonRolesToTerraformManagedServices"
    effect    = "Allow"
    actions   = ["iam:PassRole"]
    resources = local.github_actions_terraform_pass_role_arns

    condition {
      test     = "StringLike"
      variable = "iam:PassedToService"
      values = [
        "ec2.amazonaws.com",
        "ecs-tasks.amazonaws.com",
        "lambda.amazonaws.com",
      ]
    }
  }

  statement {
    sid       = "CreateElastiCacheServiceLinkedRole"
    effect    = "Allow"
    actions   = ["iam:CreateServiceLinkedRole"]
    resources = ["*"]

    condition {
      test     = "StringEquals"
      variable = "iam:AWSServiceName"
      values   = ["elasticache.amazonaws.com"]
    }
  }

  statement {
    sid       = "CreateElasticLoadBalancingServiceLinkedRole"
    effect    = "Allow"
    actions   = ["iam:CreateServiceLinkedRole"]
    resources = ["*"]

    condition {
      test     = "StringEquals"
      variable = "iam:AWSServiceName"
      values   = ["elasticloadbalancing.amazonaws.com"]
    }
  }

  statement {
    sid       = "CreateEcsAndAutoScalingServiceLinkedRoles"
    effect    = "Allow"
    actions   = ["iam:CreateServiceLinkedRole"]
    resources = ["*"]

    condition {
      test     = "StringEquals"
      variable = "iam:AWSServiceName"
      values = [
        "autoscaling.amazonaws.com",
        "ecs.amazonaws.com",
        "ecs.application-autoscaling.amazonaws.com",
      ]
    }
  }
}
