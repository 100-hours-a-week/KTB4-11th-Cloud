resource "aws_iam_role" "frontend_publish" {
  count = var.frontend_edge_enabled ? 1 : 0
  name  = "stockspoon-v2-prod-frontend-publish"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Action    = "sts:AssumeRoleWithWebIdentity"
      Principal = { Federated = aws_iam_openid_connect_provider.github_actions.arn }
      Condition = { StringEquals = {
        "token.actions.githubusercontent.com:aud" = "sts.amazonaws.com"
        "token.actions.githubusercontent.com:sub" = local.frontend_deploy_github_subject
      } }
    }]
  })
  tags = local.frontend_tags
}

resource "aws_iam_role_policy" "frontend_publish" {
  count = var.frontend_edge_enabled ? 1 : 0
  name  = "publish-production-frontend-assets-and-image"
  role  = aws_iam_role.frontend_publish[0].id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect    = "Allow"
        Action    = ["s3:ListBucket"]
        Resource  = aws_s3_bucket.frontend_assets[0].arn
        Condition = { StringLike = { "s3:prefix" = ["_next/static", "_next/static/*"] } }
      },
      {
        Effect   = "Allow"
        Action   = ["s3:GetBucketLocation"]
        Resource = aws_s3_bucket.frontend_assets[0].arn
      },
      {
        Effect   = "Allow"
        Action   = ["s3:GetObject", "s3:PutObject"]
        Resource = "${aws_s3_bucket.frontend_assets[0].arn}/_next/static/*"
      },
      {
        Effect   = "Allow"
        Action   = ["cloudfront:CreateInvalidation", "cloudfront:GetInvalidation", "cloudfront:GetDistribution"]
        Resource = aws_cloudfront_distribution.frontend[0].arn
      },
      {
        Effect   = "Allow"
        Action   = ["ecr:GetAuthorizationToken"]
        Resource = "*"
      },
      {
        Effect   = "Allow"
        Action   = ["ecr:BatchCheckLayerAvailability", "ecr:BatchGetImage", "ecr:CompleteLayerUpload", "ecr:InitiateLayerUpload", "ecr:PutImage", "ecr:UploadLayerPart"]
        Resource = "arn:aws:ecr:ap-northeast-2:${data.aws_caller_identity.github_actions_terraform.account_id}:repository/stockspoon-v2-prod-frontend"
      },
    ]
  })
}
