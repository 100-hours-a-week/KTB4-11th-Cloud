# Separate policy keeps the existing application policy below IAM's 6144-character limit.
data "aws_iam_policy_document" "terraform_ci_write_edge" {
  statement {
    sid    = "ManageFrontendAssetBucket"
    effect = "Allow"
    actions = [
      "s3:CreateBucket", "s3:DeleteBucket", "s3:DeleteBucketPolicy",
      "s3:PutBucketPolicy", "s3:PutBucketOwnershipControls",
      "s3:PutBucketPublicAccessBlock", "s3:PutBucketTagging",
      "s3:PutBucketVersioning", "s3:PutEncryptionConfiguration",
      "s3:PutLifecycleConfiguration",
    ]
    resources = [var.resource_arns.frontend_assets]
  }

  statement {
    sid       = "CreateTaggedFrontendDistribution"
    effect    = "Allow"
    actions   = ["cloudfront:CreateDistributionWithTags"]
    resources = [var.resource_arns.cloudfront_distributions]
    condition {
      test     = "StringEquals"
      variable = "aws:RequestTag/Project"
      values   = ["stockspoon"]
    }
    condition {
      test     = "StringEquals"
      variable = "aws:RequestTag/Environment"
      values   = ["v2-prod"]
    }
  }

  statement {
    sid       = "ManageFrontendDistribution"
    effect    = "Allow"
    actions   = ["cloudfront:UpdateDistribution", "cloudfront:DeleteDistribution", "cloudfront:TagResource", "cloudfront:UntagResource"]
    resources = [var.resource_arns.cloudfront_distributions]
    condition {
      test     = "StringEquals"
      variable = "aws:ResourceTag/Project"
      values   = ["stockspoon"]
    }
    condition {
      test     = "StringEquals"
      variable = "aws:ResourceTag/Environment"
      values   = ["v2-prod"]
    }
  }

  # OAC APIs do not support resource-level IAM authorization.
  statement {
    sid       = "ManageOriginAccessControl"
    effect    = "Allow"
    actions   = ["cloudfront:CreateOriginAccessControl", "cloudfront:UpdateOriginAccessControl", "cloudfront:DeleteOriginAccessControl"]
    resources = ["*"]
  }

  statement {
    sid    = "ManageEdgeCertificatesInVirginia"
    effect = "Allow"
    actions = [
      "acm:RequestCertificate", "acm:DeleteCertificate", "acm:AddTagsToCertificate",
      "acm:RemoveTagsFromCertificate", "acm:UpdateCertificateOptions",
    ]
    resources = ["*"]
    condition {
      test     = "StringEquals"
      variable = "aws:RequestedRegion"
      values   = ["us-east-1"]
    }
  }
}

# CloudFront WAF ACLs are managed in us-east-1. Keep writes scoped to this ACL.
data "aws_iam_policy_document" "terraform_ci_write_api_waf" {
  statement {
    sid = "ManageApiRateLimitAcl"
    actions = [
      "wafv2:CreateWebACL", "wafv2:UpdateWebACL", "wafv2:DeleteWebACL",
      "wafv2:TagResource", "wafv2:UntagResource",
      "wafv2:PutLoggingConfiguration", "wafv2:DeleteLoggingConfiguration",
    ]
    resources = ["arn:aws:wafv2:us-east-1:${split(":", var.resource_arns.cloudfront_distributions)[4]}:global/webacl/stockspoon-api-rate-limit/*"]
  }
  statement {
    sid = "ManageApiWafLogGroup"
    actions = [
      "logs:CreateLogGroup", "logs:DeleteLogGroup", "logs:PutRetentionPolicy",
      "logs:DeleteRetentionPolicy", "logs:TagResource", "logs:UntagResource",
    ]
    resources = ["arn:aws:logs:us-east-1:${split(":", var.resource_arns.cloudfront_distributions)[4]}:log-group:aws-waf-logs-stockspoon-api-rate-limit:*"]
  }
  # CloudWatch log delivery APIs do not support log-group resource scoping.
  statement {
    sid = "ConfigureWafLogDeliveryInVirginia"
    actions = [
      "logs:CreateLogDelivery", "logs:UpdateLogDelivery", "logs:DeleteLogDelivery",
      "logs:PutResourcePolicy",
    ]
    resources = ["*"]
    condition {
      test     = "StringEquals"
      variable = "aws:RequestedRegion"
      values   = ["us-east-1"]
    }
  }
}
