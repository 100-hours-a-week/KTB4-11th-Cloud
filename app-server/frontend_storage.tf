locals {
  frontend_assets_bucket_name = "stockspoon-v2-prod-frontend-${data.aws_caller_identity.github_actions_terraform.account_id}"
  frontend_assets_bucket_arn  = "arn:aws:s3:::${local.frontend_assets_bucket_name}"
  frontend_tags = {
    Project     = "stockspoon"
    Environment = "v2-prod"
    ManagedBy   = "Terraform"
  }
}

resource "aws_s3_bucket" "frontend_assets" {
  count         = var.frontend_edge_enabled ? 1 : 0
  bucket        = local.frontend_assets_bucket_name
  force_destroy = false
  tags          = local.frontend_tags
}

resource "aws_s3_bucket_public_access_block" "frontend_assets" {
  count                   = var.frontend_edge_enabled ? 1 : 0
  bucket                  = aws_s3_bucket.frontend_assets[0].id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_ownership_controls" "frontend_assets" {
  count  = var.frontend_edge_enabled ? 1 : 0
  bucket = aws_s3_bucket.frontend_assets[0].id
  rule {
    object_ownership = "BucketOwnerEnforced"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "frontend_assets" {
  count  = var.frontend_edge_enabled ? 1 : 0
  bucket = aws_s3_bucket.frontend_assets[0].id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_versioning" "frontend_assets" {
  count  = var.frontend_edge_enabled ? 1 : 0
  bucket = aws_s3_bucket.frontend_assets[0].id
  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_lifecycle_configuration" "frontend_assets" {
  count  = var.frontend_edge_enabled ? 1 : 0
  bucket = aws_s3_bucket.frontend_assets[0].id
  rule {
    id     = "remove-old-versions-and-incomplete-uploads"
    status = "Enabled"
    filter {}
    noncurrent_version_expiration {
      noncurrent_days = 30
    }
    expiration {
      days = 180
    }
    abort_incomplete_multipart_upload {
      days_after_initiation = 7
    }
  }
  # Preserve release assets for tabs and rollbacks, then bound accumulated old hashes.
  depends_on = [aws_s3_bucket_versioning.frontend_assets]
}

resource "aws_s3_bucket_policy" "frontend_assets" {
  count  = var.frontend_edge_enabled ? 1 : 0
  bucket = aws_s3_bucket.frontend_assets[0].id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid       = "AllowThisDistributionOnly"
        Effect    = "Allow"
        Principal = { Service = "cloudfront.amazonaws.com" }
        Action    = "s3:GetObject"
        Resource  = "${aws_s3_bucket.frontend_assets[0].arn}/_next/static/*"
        Condition = { StringEquals = { "AWS:SourceArn" = aws_cloudfront_distribution.frontend[0].arn } }
      },
      {
        Sid       = "DenyInsecureTransport"
        Effect    = "Deny"
        Principal = "*"
        Action    = "s3:*"
        Resource  = [aws_s3_bucket.frontend_assets[0].arn, "${aws_s3_bucket.frontend_assets[0].arn}/*"]
        Condition = { Bool = { "aws:SecureTransport" = "false" } }
      },
    ]
  })
  depends_on = [aws_s3_bucket_public_access_block.frontend_assets]
}
