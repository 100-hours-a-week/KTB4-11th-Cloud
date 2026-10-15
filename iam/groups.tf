locals {
  groups = toset([
    "cloud_developer",
    "stockspoon_developer",
    "terraform",
  ])

  group_policy_attachments = {
    cloud_developer_administrator_access = {
      group      = "cloud_developer"
      policy_arn = "arn:aws:iam::aws:policy/AdministratorAccess"
    }
    stockspoon_developer_read_only = {
      group      = "stockspoon_developer"
      policy_arn = "arn:aws:iam::aws:policy/ReadOnlyAccess"
    }
    stockspoon_developer_change_password = {
      group      = "stockspoon_developer"
      policy_arn = "arn:aws:iam::aws:policy/IAMUserChangePassword"
    }
    stockspoon_developer_cloudwatch_read_only = {
      group      = "stockspoon_developer"
      policy_arn = "arn:aws:iam::aws:policy/CloudWatchReadOnlyAccess"
    }
    terraform_read_only = {
      group      = "terraform"
      policy_arn = "arn:aws:iam::aws:policy/ReadOnlyAccess"
    }
  }
}

resource "aws_iam_group" "existing" {
  for_each = local.groups

  name = each.value
  path = "/"

  lifecycle {
    prevent_destroy = true
  }
}

resource "aws_iam_group_policy_attachment" "existing" {
  for_each = local.group_policy_attachments

  group      = aws_iam_group.existing[each.value.group].name
  policy_arn = each.value.policy_arn
}

resource "aws_iam_group_policy" "terraform_ci_permission_editor" {
  name  = "stockspoon-v1-terraform-ci-permission-editor"
  group = aws_iam_group.existing["terraform"].name

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid      = "WriteAppServerTerraformState"
        Effect   = "Allow"
        Action   = ["s3:PutObject"]
        Resource = "arn:aws:s3:::stockspoon-terraform-state-v1/app-server/terraform.tfstate"
      },
      {
        Sid    = "ManageAppServerTerraformLock"
        Effect = "Allow"
        Action = [
          "s3:PutObject",
          "s3:DeleteObject",
        ]
        Resource = "arn:aws:s3:::stockspoon-terraform-state-v1/app-server/terraform.tfstate.tflock"
      },
      {
        Sid    = "ManageTerraformLockFiles"
        Effect = "Allow"
        Action = [
          "s3:GetObject",
          "s3:PutObject",
          "s3:DeleteObject",
        ]
        Resource = "arn:aws:s3:::stockspoon-terraform-state-*/*.tflock"
      },
      {
        Sid    = "CreateTerraformStateBuckets"
        Effect = "Allow"
        Action = [
          "s3:CreateBucket",
          "s3:PutBucketVersioning",
          "s3:PutEncryptionConfiguration",
          "s3:PutBucketPublicAccessBlock",
          "s3:PutBucketOwnershipControls",
          "s3:PutBucketTagging",
        ]
        Resource = "arn:aws:s3:::stockspoon-terraform-state-*"
      },
      {
        Sid    = "UpdateCiTerraformManagedPolicies"
        Effect = "Allow"
        Action = [
          "iam:CreatePolicyVersion",
          "iam:DeletePolicyVersion",
          "iam:SetDefaultPolicyVersion",
        ]
        Resource = "arn:aws:iam::250832562715:policy/stockspoon-v1-github-actions-terraform-read"
      },
      {
        Sid      = "UpdateCiTerraformRoleInlinePolicies"
        Effect   = "Allow"
        Action   = ["iam:PutRolePolicy"]
        Resource = "arn:aws:iam::250832562715:role/stockspoon-v1-github-actions-terraform-apply"
      },
    ]
  })
}
