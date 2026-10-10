# Separate GitHub Actions roles keep infrastructure access independent from the
# existing ECR image-push role. The plan role can read Terraform-managed AWS
# resources and state, while the apply role can update the resources managed by
# this repository.

locals {
  github_actions_terraform_states = [
    {
      bucket = "stockspoon-terraform-state-v1"
      key    = "app-server/terraform.tfstate"
    },
    {
      bucket = "stockspoon-terraform-state-v1"
      key    = "shared-infra/terraform.tfstate"
    },
    {
      bucket = "stockspoon-terraform-state-v1"
      key    = "test-infra/terraform.tfstate"
    },
    {
      bucket = "stockspoon-terraform-state-v1"
      key    = "ai-server/infra/terraform.tfstate"
    },
    {
      bucket = "stockspoon-terraform-state-v1"
      key    = "ai-server/dashboard/terraform.tfstate"
    },
    {
      bucket = "stockspoon-terraform-state-ai-dev"
      key    = "ai-server/dev-infra/terraform.tfstate"
    },
    {
      bucket = "stockspoon-terraform-state-sqs"
      key    = "messaging/dev/terraform.tfstate"
    },
    {
      bucket = "stockspoon-terraform-state-redis"
      key    = "redis/dev/terraform.tfstate"
    },
  ]

  github_actions_terraform_state_object_arns = [
    for state in local.github_actions_terraform_states :
    "arn:aws:s3:::${state.bucket}/${state.key}"
  ]

  github_actions_terraform_lock_object_arns = [
    for state in local.github_actions_terraform_states :
    "arn:aws:s3:::${state.bucket}/${state.key}.tflock"
  ]

  github_actions_terraform_bucket_arns = distinct([
    for state in local.github_actions_terraform_states :
    "arn:aws:s3:::${state.bucket}"
  ])

  github_actions_terraform_state_prefixes = flatten([
    for state in local.github_actions_terraform_states : [
      state.key,
      "${state.key}.tflock",
    ]
  ])

  github_actions_terraform_iam_resource_arns = [
    "arn:${data.aws_partition.github_actions_terraform.partition}:iam::${data.aws_caller_identity.github_actions_terraform.account_id}:role/stockspoon-v1-app-*",
    "arn:${data.aws_partition.github_actions_terraform.partition}:iam::${data.aws_caller_identity.github_actions_terraform.account_id}:role/stockspoon-v1-ai-*",
    "arn:${data.aws_partition.github_actions_terraform.partition}:iam::${data.aws_caller_identity.github_actions_terraform.account_id}:role/stockspoon-loadtest-*",
    "arn:${data.aws_partition.github_actions_terraform.partition}:iam::${data.aws_caller_identity.github_actions_terraform.account_id}:role/stockspoon-v2-dev-*",
    "arn:${data.aws_partition.github_actions_terraform.partition}:iam::${data.aws_caller_identity.github_actions_terraform.account_id}:policy/stockspoon-v1-app-*",
    "arn:${data.aws_partition.github_actions_terraform.partition}:iam::${data.aws_caller_identity.github_actions_terraform.account_id}:policy/stockspoon-v1-ai-*",
    "arn:${data.aws_partition.github_actions_terraform.partition}:iam::${data.aws_caller_identity.github_actions_terraform.account_id}:policy/stockspoon-loadtest-*",
    "arn:${data.aws_partition.github_actions_terraform.partition}:iam::${data.aws_caller_identity.github_actions_terraform.account_id}:policy/stockspoon-v2-dev-*",
    "arn:${data.aws_partition.github_actions_terraform.partition}:iam::${data.aws_caller_identity.github_actions_terraform.account_id}:instance-profile/stockspoon-v1-app-*",
    "arn:${data.aws_partition.github_actions_terraform.partition}:iam::${data.aws_caller_identity.github_actions_terraform.account_id}:instance-profile/stockspoon-v1-ai-*",
    "arn:${data.aws_partition.github_actions_terraform.partition}:iam::${data.aws_caller_identity.github_actions_terraform.account_id}:instance-profile/stockspoon-loadtest-*",
    "arn:${data.aws_partition.github_actions_terraform.partition}:iam::${data.aws_caller_identity.github_actions_terraform.account_id}:instance-profile/stockspoon-v2-dev-*",
    "arn:${data.aws_partition.github_actions_terraform.partition}:iam::aws:policy/AmazonSSMManagedInstanceCore",
  ]

  github_actions_terraform_pass_role_arns = [
    for role_arn in local.github_actions_terraform_iam_resource_arns : role_arn
    if startswith(role_arn, "arn:${data.aws_partition.github_actions_terraform.partition}:iam::${data.aws_caller_identity.github_actions_terraform.account_id}:role/")
  ]

  github_actions_terraform_lambda_arns = [
    for prefix in ["stockspoon-v1-app-", "stockspoon-v1-ai-", "stockspoon-v2-dev-"] :
    "arn:${data.aws_partition.github_actions_terraform.partition}:lambda:ap-northeast-2:${data.aws_caller_identity.github_actions_terraform.account_id}:function:${prefix}*"
  ]

  github_actions_terraform_secret_arns = [
    for name in [
      "stockspoon/v1/app/discord-webhook",
      "stockspoon/v1/ai/discord-webhook",
      "stockspoon/v2/dev/sqs/discord-webhook",
      "stockspoon/v2/dev/valkey/discord-webhook",
    ] :
    "arn:${data.aws_partition.github_actions_terraform.partition}:secretsmanager:ap-northeast-2:${data.aws_caller_identity.github_actions_terraform.account_id}:secret:${name}-*"
  ]

  github_actions_terraform_sqs_queue_arns = [
    "arn:${data.aws_partition.github_actions_terraform.partition}:sqs:ap-northeast-2:${data.aws_caller_identity.github_actions_terraform.account_id}:stockspoon-v2-dev-*",
  ]

  github_actions_terraform_ecr_public_repository_arns = [
    for name in [
      "stockspoon-v1-backend",
      "stockspoon-v1-frontend",
      "stockspoon-v1-ai",
    ] :
    "arn:${data.aws_partition.github_actions_terraform.partition}:ecr-public::${data.aws_caller_identity.github_actions_terraform.account_id}:repository/${name}"
  ]

  github_actions_terraform_ses_identity_arns = [
    "arn:${data.aws_partition.github_actions_terraform.partition}:ses:ap-northeast-2:${data.aws_caller_identity.github_actions_terraform.account_id}:identity/notify.stock-spoon.com",
    "arn:${data.aws_partition.github_actions_terraform.partition}:ses:ap-northeast-2:${data.aws_caller_identity.github_actions_terraform.account_id}:identity/ruby0656@naver.com",
  ]
}

data "aws_caller_identity" "github_actions_terraform" {}

data "aws_partition" "github_actions_terraform" {}

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

data "aws_iam_policy_document" "github_actions_terraform_read" {
  statement {
    sid    = "ReadResourcesManagedByTerraform"
    effect = "Allow"
    actions = [
      "cloudwatch:Describe*",
      "cloudwatch:Get*",
      "cloudwatch:List*",
      "ec2:Describe*",
      "ec2:Get*",
      "ecr-public:Describe*",
      "ecr-public:GetAuthorizationToken",
      "ecr-public:GetRepositoryCatalogData",
      "ecr-public:GetRepositoryPolicy",
      "ecr-public:List*",
      "elasticache:Describe*",
      "elasticache:List*",
      "iam:Get*",
      "iam:List*",
      "lambda:Get*",
      "lambda:List*",
      "logs:Describe*",
      "logs:Get*",
      "logs:List*",
      "route53:Get*",
      "route53:List*",
      "secretsmanager:DescribeSecret",
      "secretsmanager:List*",
      "ses:Describe*",
      "ses:Get*",
      "ses:List*",
      "sqs:Get*",
      "sqs:List*",
      "sts:GetCallerIdentity",
      "sts:GetServiceBearerToken",
    ]
    resources = ["*"]
  }

  statement {
    sid       = "ReadRepositorySecretPolicies"
    effect    = "Allow"
    actions   = ["secretsmanager:GetResourcePolicy"]
    resources = local.github_actions_terraform_secret_arns
  }

  statement {
    sid       = "ReadCanonicalUbuntuAmiParameter"
    effect    = "Allow"
    actions   = ["ssm:GetParameter"]
    resources = ["arn:aws:ssm:ap-northeast-2::parameter/aws/service/canonical/ubuntu/server/resolute/stable/current/amd64/hvm/ebs-gp3/ami-id"]
  }

  statement {
    sid       = "ReadTerraformStates"
    effect    = "Allow"
    actions   = ["s3:GetObject"]
    resources = local.github_actions_terraform_state_object_arns
  }

  statement {
    sid    = "LockTerraformStates"
    effect = "Allow"
    actions = [
      "s3:DeleteObject",
      "s3:GetObject",
      "s3:PutObject",
    ]
    resources = local.github_actions_terraform_lock_object_arns
  }

  statement {
    sid       = "LocateTerraformStateBuckets"
    effect    = "Allow"
    actions   = ["s3:GetBucketLocation"]
    resources = local.github_actions_terraform_bucket_arns
  }

  statement {
    sid       = "ListTerraformStatePrefixes"
    effect    = "Allow"
    actions   = ["s3:ListBucket"]
    resources = local.github_actions_terraform_bucket_arns
    condition {
      test     = "StringLike"
      variable = "s3:prefix"
      values   = local.github_actions_terraform_state_prefixes
    }
  }
}

resource "aws_iam_policy" "github_actions_terraform_read" {
  name        = "stockspoon-v1-github-actions-terraform-read"
  description = "Read Terraform-managed AWS resources and the existing Terraform state objects"
  policy      = data.aws_iam_policy_document.github_actions_terraform_read.json
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

data "aws_iam_policy_document" "github_actions_terraform_apply_state" {
  statement {
    sid    = "WriteTerraformStates"
    effect = "Allow"
    actions = [
      "s3:GetObject",
      "s3:PutObject",
    ]
    resources = local.github_actions_terraform_state_object_arns
  }
}

resource "aws_iam_role_policy" "github_actions_terraform_apply_state" {
  name   = "stockspoon-v1-github-actions-terraform-state-write"
  role   = aws_iam_role.github_actions_terraform_apply.id
  policy = data.aws_iam_policy_document.github_actions_terraform_apply_state.json
}

data "aws_iam_policy_document" "github_actions_terraform_apply_resources" {
  statement {
    sid    = "ManageEc2AndElastiCacheInSeoul"
    effect = "Allow"
    actions = [
      "ec2:*",
      "elasticache:*",
    ]
    resources = ["*"]

    condition {
      test     = "StringEquals"
      variable = "aws:RequestedRegion"
      values   = ["ap-northeast-2"]
    }
  }

  statement {
    sid    = "ManageRepositoryObservabilityInSeoul"
    effect = "Allow"
    actions = [
      "cloudwatch:DeleteAlarms",
      "cloudwatch:DeleteDashboards",
      "cloudwatch:PutDashboard",
      "cloudwatch:PutMetricAlarm",
      "cloudwatch:TagResource",
      "cloudwatch:UntagResource",
      "logs:CreateLogGroup",
      "logs:DeleteLogGroup",
      "logs:DeleteMetricFilter",
      "logs:DeleteRetentionPolicy",
      "logs:PutMetricFilter",
      "logs:PutRetentionPolicy",
      "logs:TagResource",
      "logs:UntagResource",
    ]
    resources = ["*"]

    condition {
      test     = "StringEquals"
      variable = "aws:RequestedRegion"
      values   = ["ap-northeast-2"]
    }
  }

  statement {
    sid    = "ManageRepositoryLambdaFunctions"
    effect = "Allow"
    actions = [
      "lambda:AddPermission",
      "lambda:CreateFunction",
      "lambda:DeleteFunction",
      "lambda:RemovePermission",
      "lambda:TagResource",
      "lambda:UntagResource",
      "lambda:UpdateFunctionCode",
      "lambda:UpdateFunctionConfiguration",
    ]
    resources = local.github_actions_terraform_lambda_arns
  }

  statement {
    sid    = "ManageRepositorySecrets"
    effect = "Allow"
    actions = [
      "secretsmanager:CreateSecret",
      "secretsmanager:DeleteSecret",
      "secretsmanager:PutResourcePolicy",
      "secretsmanager:RestoreSecret",
      "secretsmanager:TagResource",
      "secretsmanager:UntagResource",
      "secretsmanager:UpdateSecret",
    ]
    resources = local.github_actions_terraform_secret_arns
  }

  statement {
    sid    = "ManageRepositoryQueues"
    effect = "Allow"
    actions = [
      "sqs:CreateQueue",
      "sqs:DeleteQueue",
      "sqs:SetQueueAttributes",
      "sqs:TagQueue",
      "sqs:UntagQueue",
    ]
    resources = local.github_actions_terraform_sqs_queue_arns
  }

  statement {
    sid    = "ManageApplicationEcrPublicRepositories"
    effect = "Allow"
    actions = [
      "ecr-public:CreateRepository",
      "ecr-public:DeleteRepository",
      "ecr-public:DeleteRepositoryPolicy",
      "ecr-public:PutRepositoryCatalogData",
      "ecr-public:SetRepositoryPolicy",
      "ecr-public:TagResource",
      "ecr-public:UntagResource",
    ]
    resources = local.github_actions_terraform_ecr_public_repository_arns
  }

  statement {
    sid    = "ManageApplicationSesIdentities"
    effect = "Allow"
    actions = [
      "ses:DeleteIdentity",
      "ses:VerifyDomainDkim",
      "ses:VerifyDomainIdentity",
      "ses:VerifyEmailIdentity",
    ]
    resources = local.github_actions_terraform_ses_identity_arns
  }

  statement {
    sid       = "ChangeRecordsInApplicationHostedZone"
    effect    = "Allow"
    actions   = ["route53:ChangeResourceRecordSets"]
    resources = ["arn:aws:route53:::hostedzone/${data.aws_route53_zone.app_alert_email.zone_id}"]
  }

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
    sid       = "PassStockspoonRolesToTerraformManagedServices"
    effect    = "Allow"
    actions   = ["iam:PassRole"]
    resources = local.github_actions_terraform_pass_role_arns

    condition {
      test     = "StringLike"
      variable = "iam:PassedToService"
      values = [
        "ec2.amazonaws.com",
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
}

resource "aws_iam_role_policy" "github_actions_terraform_apply_resources" {
  name   = "stockspoon-v1-github-actions-terraform-resource-write"
  role   = aws_iam_role.github_actions_terraform_apply.id
  policy = data.aws_iam_policy_document.github_actions_terraform_apply_resources.json
}

output "github_actions_terraform_plan_role_arn" {
  description = "AWS role ARN to set as the GitHub Actions repository variable AWS_TERRAFORM_PLAN_ROLE_ARN"
  value       = aws_iam_role.github_actions_terraform_plan.arn
}

output "github_actions_terraform_apply_role_arn" {
  description = "AWS role ARN to set as the GitHub Actions repository variable AWS_TERRAFORM_APPLY_ROLE_ARN"
  value       = aws_iam_role.github_actions_terraform_apply.arn
}
