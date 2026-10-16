data "aws_iam_policy_document" "terraform_ci_write_application" {
  statement {
    sid    = "ManageAlbAccessLogBucket"
    effect = "Allow"
    actions = [
      "s3:CreateBucket",
      "s3:DeleteBucket",
      "s3:DeleteBucketPolicy",
      "s3:PutBucket*",
      "s3:PutEncryptionConfiguration",
      "s3:PutLifecycleConfiguration",
    ]
    resources = [local.alb_access_log_bucket_arn]
  }

  statement {
    sid    = "ManageStockLogoBucket"
    effect = "Allow"
    actions = [
      "s3:CreateBucket",
      "s3:DeleteBucket",
      "s3:DeleteBucketPolicy",
      "s3:PutBucketPolicy",
      "s3:PutBucketOwnershipControls",
      "s3:PutBucketPublicAccessBlock",
      "s3:PutBucketTagging",
      "s3:PutBucketVersioning",
      "s3:PutEncryptionConfiguration",
    ]
    resources = [local.stock_logo_bucket_arn]
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
    sid    = "ManageApplicationEcrRepositories"
    effect = "Allow"
    actions = [
      "ecr:CreateRepository",
      "ecr:DeleteLifecyclePolicy",
      "ecr:DeleteRepository",
      "ecr:DeleteRepositoryPolicy",
      "ecr:PutImageScanningConfiguration",
      "ecr:PutImageTagMutability",
      "ecr:PutLifecyclePolicy",
      "ecr:SetRepositoryPolicy",
      "ecr:TagResource",
      "ecr:UntagResource",
    ]
    resources = local.github_actions_terraform_ecr_repository_arns
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
}
