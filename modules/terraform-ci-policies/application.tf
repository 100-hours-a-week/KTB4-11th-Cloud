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
    resources = [var.resource_arns.alb_logs]
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
    resources = [var.resource_arns.stock_logos]
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
    resources = var.resource_arns.lambda
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
    resources = var.resource_arns.secrets
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
    resources = var.resource_arns.queues
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
    resources = var.resource_arns.ecr_public
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
    resources = var.resource_arns.ecr_private
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
    resources = var.resource_arns.ses
  }

  statement {
    sid       = "ChangeRecordsInApplicationHostedZone"
    effect    = "Allow"
    actions   = ["route53:ChangeResourceRecordSets"]
    resources = [var.resource_arns.hosted_zone]
  }
}
