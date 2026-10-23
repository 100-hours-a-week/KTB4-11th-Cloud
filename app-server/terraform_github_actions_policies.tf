# GitHub Actions Terraform policies separate resource discovery, state access,
# state writes, and resource writes by responsibility.

locals {
  github_actions_terraform_states = [
    {
      bucket = "stockspoon-terraform-state-v1"
      key    = "app-server/terraform.tfstate"
    },
    {
      bucket = "stockspoon-terraform-state-v1"
      key    = "iam/terraform.tfstate"
    },
    {
      bucket = "stockspoon-terraform-state-v1"
      key    = "storage/terraform.tfstate"
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
      bucket = "stockspoon-terraform-state-sqs"
      key    = "messaging/prod/terraform.tfstate"
    },
    {
      bucket = "stockspoon-terraform-state-redis"
      key    = "redis/dev/terraform.tfstate"
    },
    {
      bucket = "stockspoon-terraform-state-redis"
      key    = "redis/prod/terraform.tfstate"
    },
    {
      bucket = "stockspoon-terraform-state-v2"
      key    = "ecr/terraform.tfstate"
    },
    {
      bucket = "stockspoon-terraform-state-v2"
      key    = "ecs/terraform.tfstate"
    },
    {
      bucket = "stockspoon-terraform-state-v2"
      key    = "monitoring/terraform.tfstate"
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
    "arn:${data.aws_partition.github_actions_terraform.partition}:iam::${data.aws_caller_identity.github_actions_terraform.account_id}:role/stockspoon-v2-prod-*",
    "arn:${data.aws_partition.github_actions_terraform.partition}:iam::${data.aws_caller_identity.github_actions_terraform.account_id}:policy/stockspoon-v1-app-*",
    "arn:${data.aws_partition.github_actions_terraform.partition}:iam::${data.aws_caller_identity.github_actions_terraform.account_id}:policy/stockspoon-v1-ai-*",
    "arn:${data.aws_partition.github_actions_terraform.partition}:iam::${data.aws_caller_identity.github_actions_terraform.account_id}:policy/stockspoon-loadtest-*",
    "arn:${data.aws_partition.github_actions_terraform.partition}:iam::${data.aws_caller_identity.github_actions_terraform.account_id}:policy/stockspoon-stock-logo-*",
    "arn:${data.aws_partition.github_actions_terraform.partition}:iam::${data.aws_caller_identity.github_actions_terraform.account_id}:policy/stockspoon-v2-dev-*",
    "arn:${data.aws_partition.github_actions_terraform.partition}:iam::${data.aws_caller_identity.github_actions_terraform.account_id}:policy/stockspoon-v2-prod-*",
    "arn:${data.aws_partition.github_actions_terraform.partition}:iam::${data.aws_caller_identity.github_actions_terraform.account_id}:instance-profile/stockspoon-v1-app-*",
    "arn:${data.aws_partition.github_actions_terraform.partition}:iam::${data.aws_caller_identity.github_actions_terraform.account_id}:instance-profile/stockspoon-v1-ai-*",
    "arn:${data.aws_partition.github_actions_terraform.partition}:iam::${data.aws_caller_identity.github_actions_terraform.account_id}:instance-profile/stockspoon-loadtest-*",
    "arn:${data.aws_partition.github_actions_terraform.partition}:iam::${data.aws_caller_identity.github_actions_terraform.account_id}:instance-profile/stockspoon-v2-dev-*",
    "arn:${data.aws_partition.github_actions_terraform.partition}:iam::${data.aws_caller_identity.github_actions_terraform.account_id}:instance-profile/stockspoon-v2-prod-*",
    "arn:${data.aws_partition.github_actions_terraform.partition}:iam::aws:policy/AmazonSSMManagedInstanceCore",
  ]

  github_actions_terraform_pass_role_arns = [
    for role_arn in local.github_actions_terraform_iam_resource_arns : role_arn
    if startswith(role_arn, "arn:${data.aws_partition.github_actions_terraform.partition}:iam::${data.aws_caller_identity.github_actions_terraform.account_id}:role/")
  ]

  backend_rollback_parameter_arn       = "arn:${data.aws_partition.github_actions_terraform.partition}:ssm:ap-northeast-2:${data.aws_caller_identity.github_actions_terraform.account_id}:parameter/stockspoon/operations/prod/backend-routing/rollback-latch"
  backend_datasource_url_parameter_arn = "arn:${data.aws_partition.github_actions_terraform.partition}:ssm:ap-northeast-2:${data.aws_caller_identity.github_actions_terraform.account_id}:parameter/stockspoon/v2/prod/backend/SPRING_DATASOURCE_URL"

  github_actions_terraform_lambda_arns = [
    for prefix in ["stockspoon-v1-app-", "stockspoon-v1-ai-", "stockspoon-v2-dev-", "stockspoon-v2-prod-"] :
    "arn:${data.aws_partition.github_actions_terraform.partition}:lambda:ap-northeast-2:${data.aws_caller_identity.github_actions_terraform.account_id}:function:${prefix}*"
  ]

  github_actions_terraform_secret_arns = [
    for name in [
      "stockspoon/v1/app/discord-webhook",
      "stockspoon/v1/ai/discord-webhook",
      "stockspoon/v2/dev/sqs/discord-webhook",
      "stockspoon/v2/prod/sqs/discord-webhook",
      "stockspoon/v2/dev/valkey/discord-webhook",
      "stockspoon/v2/prod/valkey/discord-webhook",
    ] :
    "arn:${data.aws_partition.github_actions_terraform.partition}:secretsmanager:ap-northeast-2:${data.aws_caller_identity.github_actions_terraform.account_id}:secret:${name}-*"
  ]

  github_actions_terraform_sqs_queue_arns = [
    "arn:${data.aws_partition.github_actions_terraform.partition}:sqs:ap-northeast-2:${data.aws_caller_identity.github_actions_terraform.account_id}:stockspoon-v2-dev-*",
    "arn:${data.aws_partition.github_actions_terraform.partition}:sqs:ap-northeast-2:${data.aws_caller_identity.github_actions_terraform.account_id}:stockspoon-v2-prod-*",
  ]

  github_actions_terraform_ecr_public_repository_arns = [
    for name in [
      "stockspoon-v1-backend",
      "stockspoon-v1-frontend",
      "stockspoon-v1-ai",
      "stockspoon-v2-backend",
      "stockspoon-v2-frontend",
    ] :
    "arn:${data.aws_partition.github_actions_terraform.partition}:ecr-public::${data.aws_caller_identity.github_actions_terraform.account_id}:repository/${name}"
  ]

  # ecr root가 관리하는 Private ECR Repository (stockspoon-{버전}-{환경}-{서비스})
  github_actions_terraform_ecr_repository_arns = [
    for name in [
      "stockspoon-v2-prod-backend",
      "stockspoon-v2-prod-frontend",
    ] :
    "arn:${data.aws_partition.github_actions_terraform.partition}:ecr:ap-northeast-2:${data.aws_caller_identity.github_actions_terraform.account_id}:repository/${name}"
  ]

  github_actions_terraform_ses_identity_arns = [
    "arn:${data.aws_partition.github_actions_terraform.partition}:ses:ap-northeast-2:${data.aws_caller_identity.github_actions_terraform.account_id}:identity/notify.stock-spoon.com",
    "arn:${data.aws_partition.github_actions_terraform.partition}:ses:ap-northeast-2:${data.aws_caller_identity.github_actions_terraform.account_id}:identity/ruby0656@naver.com",
  ]

  # storage root와 IAM 정책에서 동일한 결정적 이름을 사용한다.
  stock_logo_bucket_name = "stockspoon-stock-logos-${data.aws_caller_identity.github_actions_terraform.account_id}"
  stock_logo_bucket_arn  = "arn:${data.aws_partition.github_actions_terraform.partition}:s3:::${local.stock_logo_bucket_name}"

  github_actions_terraform_account_iam_arns = concat(
    [
      for user in [
        "eric",
        "ezra",
        "lily",
        "pattie",
        "pattie_for_terraform",
        "river",
        "stella",
        "stella_for_terraform",
      ] : "arn:${data.aws_partition.github_actions_terraform.partition}:iam::${data.aws_caller_identity.github_actions_terraform.account_id}:user/${user}"
    ],
    [
      for group in [
        "cloud_developer",
        "stockspoon_developer",
        "terraform",
      ] : "arn:${data.aws_partition.github_actions_terraform.partition}:iam::${data.aws_caller_identity.github_actions_terraform.account_id}:group/${group}"
    ],
  )
}

data "aws_caller_identity" "github_actions_terraform" {}

data "aws_partition" "github_actions_terraform" {}

data "aws_iam_policy_document" "github_actions_terraform_resource_read" {
  # DescribeParameters does not support parameter-level resource scoping.
  # Grant metadata discovery in Seoul; parameter values remain scoped below.
  statement {
    sid       = "DescribeSsmParameterMetadataInSeoul"
    effect    = "Allow"
    actions   = ["ssm:DescribeParameters"]
    resources = ["*"]

    condition {
      test     = "StringEquals"
      variable = "aws:RequestedRegion"
      values   = ["ap-northeast-2"]
    }
  }

  statement {
    sid       = "ReadBackendRollbackLatch"
    effect    = "Allow"
    actions   = ["ssm:GetParameter", "ssm:GetParameters", "ssm:ListTagsForResource"]
    resources = [local.backend_rollback_parameter_arn]
  }

  statement {
    sid       = "ReadBackendDatasourceUrl"
    effect    = "Allow"
    actions   = ["ssm:GetParameter", "ssm:GetParameters", "ssm:ListTagsForResource"]
    resources = [local.backend_datasource_url_parameter_arn]
  }

  statement {
    sid       = "ReadBackendCollectorUrl"
    effect    = "Allow"
    actions   = ["ssm:GetParameter", "ssm:GetParameters", "ssm:ListTagsForResource"]
    resources = ["arn:${data.aws_partition.github_actions_terraform.partition}:ssm:ap-northeast-2:${data.aws_caller_identity.github_actions_terraform.account_id}:parameter/stockspoon/v2/prod/backend/KIWOOM_COLLECTOR_URL"]
  }

  statement {
    sid     = "ReadMonitoringDiscordWebhookParameters"
    effect  = "Allow"
    actions = ["ssm:GetParameter", "ssm:GetParameters", "ssm:ListTagsForResource"]
    resources = [
      for name in [
        "dev/app",
        "dev/ai",
        "prod/market-http",
        "prod/be",
        "prod/fe",
        "prod/alb",
      ] :
      "arn:${data.aws_partition.github_actions_terraform.partition}:ssm:ap-northeast-2:${data.aws_caller_identity.github_actions_terraform.account_id}:parameter/stockspoon/monitoring/${name}/discord-webhook"
    ]
  }

  # AI roots own SecureString parameters under separate environment prefixes.
  statement {
    sid     = "ReadAiSecretParameters"
    effect  = "Allow"
    actions = ["ssm:GetParameter", "ssm:GetParameters", "ssm:ListTagsForResource"]
    resources = [
      for environment in ["dev", "prod"] :
      "arn:${data.aws_partition.github_actions_terraform.partition}:ssm:ap-northeast-2:${data.aws_caller_identity.github_actions_terraform.account_id}:parameter/stockspoon/ai/${environment}/*"
    ]
  }

  # ListAliases does not support resource-level scoping; restrict it to Seoul.
  statement {
    sid       = "ListKmsAliasesInSeoul"
    effect    = "Allow"
    actions   = ["kms:ListAliases"]
    resources = ["*"]

    condition {
      test     = "StringEquals"
      variable = "aws:RequestedRegion"
      values   = ["ap-northeast-2"]
    }
  }

  # The KMS alias data source follows ListAliases with DescribeKey by alias.
  # Limit key metadata reads to the AWS-managed SSM alias in Seoul.
  statement {
    sid     = "DescribeSsmKmsKeyInSeoul"
    effect  = "Allow"
    actions = ["kms:DescribeKey"]
    resources = [
      "arn:${data.aws_partition.github_actions_terraform.partition}:kms:ap-northeast-2:${data.aws_caller_identity.github_actions_terraform.account_id}:key/*",
    ]

    condition {
      test     = "StringEquals"
      variable = "kms:RequestAlias"
      values   = ["alias/aws/ssm"]
    }
  }

  statement {
    effect = "Allow"
    actions = [
      "acm:Describe*",
      "acm:Get*",
      "acm:List*",
      "cloudfront:GetDistribution",
      "cloudfront:GetDistributionConfig",
      "cloudfront:GetOriginAccessControl",
      "cloudfront:GetCachePolicy",
      "cloudfront:GetOriginRequestPolicy",
      "cloudfront:ListCachePolicies",
      "cloudfront:ListOriginRequestPolicies",
      "cloudfront:ListTagsForResource",
      "cloudwatch:Describe*",
      "cloudwatch:Get*",
      "cloudwatch:List*",
      "autoscaling:Describe*",
      "application-autoscaling:Describe*",
      "application-autoscaling:ListTagsForResource",
      "ec2:Describe*",
      "ec2:Get*",
      "ecr:Describe*",
      "ecr:GetLifecyclePolicy",
      "ecr:GetRepositoryPolicy",
      "ecr:List*",
      "ecr-public:Describe*",
      "ecr-public:GetAuthorizationToken",
      "ecr-public:GetRepositoryCatalogData",
      "ecr-public:GetRepositoryPolicy",
      "ecr-public:List*",
      "elasticache:Describe*",
      "elasticache:List*",
      "ecs:Describe*",
      "ecs:List*",
      "events:DescribeRule",
      "events:ListTargetsByRule",
      "events:ListTagsForResource",
      "elasticloadbalancing:Describe*",
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

  # Terraform refreshes Cloud Map resources while planning the ECS root.
  # Keep read access separate from the apply-only Cloud Map write policy.
  statement {
    sid    = "ReadCloudMapResourcesInSeoul"
    effect = "Allow"
    actions = [
      "servicediscovery:GetNamespace",
      "servicediscovery:GetService",
    ]
    resources = [
      "arn:${data.aws_partition.github_actions_terraform.partition}:servicediscovery:ap-northeast-2:${data.aws_caller_identity.github_actions_terraform.account_id}:namespace/*",
      "arn:${data.aws_partition.github_actions_terraform.partition}:servicediscovery:ap-northeast-2:${data.aws_caller_identity.github_actions_terraform.account_id}:service/*",
    ]
  }

  # Cloud Map does not support resource-level scoping for ListTagsForResource.
  statement {
    sid       = "ReadCloudMapResourceTagsInSeoul"
    effect    = "Allow"
    actions   = ["servicediscovery:ListTagsForResource"]
    resources = ["*"]

    condition {
      test     = "StringEquals"
      variable = "aws:RequestedRegion"
      values   = ["ap-northeast-2"]
    }
  }

  statement {
    effect = "Allow"
    actions = [
      "s3:Get*",
      "s3:ListBucket",
    ]
    resources = concat([
      local.alb_access_log_bucket_arn,
      local.stock_logo_bucket_arn,
      local.frontend_assets_bucket_arn,
      ], [
      for kind in ["loki", "tempo"] :
      "arn:aws:s3:::stockspoon-v2-prod-telemetry-${kind}-${data.aws_caller_identity.github_actions_terraform.account_id}-ap-northeast-2"
    ])
  }

  statement {
    effect    = "Allow"
    actions   = ["secretsmanager:GetResourcePolicy"]
    resources = local.github_actions_terraform_secret_arns
  }

  statement {
    effect  = "Allow"
    actions = ["ssm:GetParameter"]
    resources = [
      "arn:aws:ssm:ap-northeast-2::parameter/aws/service/canonical/ubuntu/server/resolute/stable/current/amd64/hvm/ebs-gp3/ami-id",
      "arn:aws:ssm:ap-northeast-2::parameter/aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-x86_64",
    ]
  }

  statement {
    effect    = "Allow"
    actions   = ["ssm:GetParameter", "ssm:GetParameters"]
    resources = ["arn:aws:ssm:ap-northeast-2::parameter/aws/service/ecs/optimized-ami/amazon-linux-2023/*"]
  }
}

resource "aws_iam_policy" "github_actions_terraform_read" {
  # AWS provider는 description 변경 시 정책을 교체하므로 기존 설명을 유지한다.
  name        = "stockspoon-v1-github-actions-terraform-read"
  description = "Read Terraform-managed AWS resources and the existing Terraform state objects"
  policy      = data.aws_iam_policy_document.github_actions_terraform_resource_read.json

  # 신규 state 정책이 먼저 연결되어 migration 중 state 접근 권한이 끊기지 않게 한다.
  depends_on = [
    aws_iam_role_policy_attachment.github_actions_terraform_apply_state_access,
    aws_iam_role_policy_attachment.github_actions_terraform_plan_state_access,
  ]
}

data "aws_iam_policy_document" "github_actions_terraform_state_access" {
  statement {
    sid       = "ReadTerraformStates"
    effect    = "Allow"
    actions   = ["s3:GetObject"]
    resources = local.github_actions_terraform_state_object_arns
  }

  statement {
    sid    = "ManageTerraformLocks"
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

resource "aws_iam_policy" "github_actions_terraform_state_access" {
  name        = "stockspoon-v1-github-actions-terraform-state-access"
  description = "Read Terraform states and manage Terraform lock files"
  policy      = data.aws_iam_policy_document.github_actions_terraform_state_access.json
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

module "terraform_ci_policies" {
  source = "../modules/terraform-ci-policies"

  resource_arns = {
    backend_rollback_parameter       = local.backend_rollback_parameter_arn
    backend_datasource_url_parameter = local.backend_datasource_url_parameter_arn
    alb_logs                         = local.alb_access_log_bucket_arn
    stock_logos                      = local.stock_logo_bucket_arn
    frontend_assets                  = local.frontend_assets_bucket_arn
    cloudfront_distributions         = "arn:aws:cloudfront::${data.aws_caller_identity.github_actions_terraform.account_id}:distribution/*"
    lambda                           = local.github_actions_terraform_lambda_arns
    secrets                          = local.github_actions_terraform_secret_arns
    queues                           = local.github_actions_terraform_sqs_queue_arns
    ecr_public                       = local.github_actions_terraform_ecr_public_repository_arns
    ecr_private                      = local.github_actions_terraform_ecr_repository_arns
    ses                              = local.github_actions_terraform_ses_identity_arns
    iam_resources                    = local.github_actions_terraform_iam_resource_arns
    iam_accounts                     = local.github_actions_terraform_account_iam_arns
    pass_roles                       = local.github_actions_terraform_pass_role_arns
    hosted_zone                      = "arn:aws:route53:::hostedzone/${data.aws_route53_zone.app_alert_email.zone_id}"
  }
}

locals {
  terraform_ci_write_documents = module.terraform_ci_policies.documents
}

resource "aws_iam_policy" "terraform_ci_write" {
  for_each = local.terraform_ci_write_documents

  name        = "stockspoon-v1-github-actions-terraform-write-${each.key}"
  description = "Terraform CI resource writes: ${each.key}"
  policy      = each.value

  lifecycle {
    precondition {
      condition     = length(jsonencode(jsondecode(each.value))) <= 6144
      error_message = "Managed IAM policies must fit within 6144 characters."
    }
  }
}

resource "aws_iam_role_policy_attachment" "terraform_ci_write" {
  for_each = aws_iam_policy.terraform_ci_write

  role       = aws_iam_role.github_actions_terraform_apply.name
  policy_arn = each.value.arn
}

# 1단계에서는 새 정책 연결과 동시에 기존 권한을 유지한다.
# 연결 검증 후 retain_legacy_terraform_ci_write_policy=false로 2단계 전환한다.
resource "aws_iam_role_policy" "github_actions_terraform_apply_resources" {
  count = var.retain_legacy_terraform_ci_write_policy ? 1 : 0

  name = "stockspoon-v1-github-actions-terraform-resource-write"
  role = aws_iam_role.github_actions_terraform_apply.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = flatten([
      for document in values(local.terraform_ci_write_documents) : [
        for statement in jsondecode(document).Statement : {
          for key, value in statement : key => value if key != "Sid"
        }
      ]
    ])
  })
}

moved {
  from = aws_iam_role_policy.github_actions_terraform_apply_resources
  to   = aws_iam_role_policy.github_actions_terraform_apply_resources[0]
}
