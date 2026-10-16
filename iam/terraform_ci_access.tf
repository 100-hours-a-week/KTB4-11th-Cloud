locals {
  terraform_ci_policy_prefix = "arn:${data.aws_partition.current.partition}:iam::${data.aws_caller_identity.current.account_id}:policy/stockspoon-v1-github-actions-terraform"
  terraform_ci_apply_role    = "arn:${data.aws_partition.current.partition}:iam::${data.aws_caller_identity.current.account_id}:role/stockspoon-v1-github-actions-terraform-apply"
  terraform_ci_write_policies = [
    for category in ["compute", "application", "observability", "identity"] :
    "${local.terraform_ci_policy_prefix}-write-${category}"
  ]
}

data "aws_iam_policy_document" "terraform_ci_managed_policy_editor" {
  statement {
    sid    = "ManageCiWritePolicies"
    effect = "Allow"
    actions = [
      "iam:CreatePolicy", "iam:DeletePolicy",
      "iam:TagPolicy", "iam:UntagPolicy",
    ]
    resources = local.terraform_ci_write_policies
  }

  statement {
    sid    = "UpdateCiManagedPolicyVersions"
    effect = "Allow"
    actions = [
      "iam:CreatePolicyVersion", "iam:DeletePolicyVersion", "iam:SetDefaultPolicyVersion",
    ]
    resources = concat(local.terraform_ci_write_policies, [
      "${local.terraform_ci_policy_prefix}-read",
      "${local.terraform_ci_policy_prefix}-state-access",
    ])
  }

  statement {
    sid       = "AttachCiWritePoliciesToApplyRole"
    effect    = "Allow"
    actions   = ["iam:AttachRolePolicy", "iam:DetachRolePolicy"]
    resources = [local.terraform_ci_apply_role]

    condition {
      test     = "ArnEquals"
      variable = "iam:PolicyARN"
      values   = local.terraform_ci_write_policies
    }
  }

  statement {
    sid       = "RemoveLegacyCiInlinePolicy"
    effect    = "Allow"
    actions   = ["iam:DeleteRolePolicy"]
    resources = [local.terraform_ci_apply_role]
  }
}

resource "aws_iam_policy" "terraform_ci_managed_policy_editor" {
  name        = "stockspoon-v1-terraform-ci-managed-policy-editor"
  description = "Allow terraform group members to maintain scoped Terraform CI managed policies"
  policy      = data.aws_iam_policy_document.terraform_ci_managed_policy_editor.json
}

resource "aws_iam_group_policy_attachment" "terraform_ci_managed_policy_editor" {
  group      = aws_iam_group.existing["terraform"].name
  policy_arn = aws_iam_policy.terraform_ci_managed_policy_editor.arn
}
