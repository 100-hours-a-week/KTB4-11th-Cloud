data "aws_caller_identity" "current" {}

locals {
  stock_logo_bucket_name = "stockspoon-stock-logos-${data.aws_caller_identity.current.account_id}"
}

# 주식 로고 원본 저장소. 외부 공개는 차단하고 향후 CloudFront OAC를 통해 제공한다.
resource "aws_s3_bucket" "stock_logos" {
  bucket        = local.stock_logo_bucket_name
  force_destroy = false

  tags = {
    Name        = local.stock_logo_bucket_name
    Project     = "stockspoon"
    Environment = "shared"
    ManagedBy   = "Terraform"
  }

  lifecycle {
    prevent_destroy = true
  }
}

resource "aws_s3_bucket_ownership_controls" "stock_logos" {
  bucket = aws_s3_bucket.stock_logos.id

  rule {
    object_ownership = "BucketOwnerEnforced"
  }
}

resource "aws_s3_bucket_public_access_block" "stock_logos" {
  bucket = aws_s3_bucket.stock_logos.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_server_side_encryption_configuration" "stock_logos" {
  bucket = aws_s3_bucket.stock_logos.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_versioning" "stock_logos" {
  bucket = aws_s3_bucket.stock_logos.id

  versioning_configuration {
    status = "Enabled"
  }
}

data "aws_iam_policy_document" "stock_logos" {
  statement {
    sid     = "DenyInsecureTransport"
    effect  = "Deny"
    actions = ["s3:*"]

    principals {
      type        = "*"
      identifiers = ["*"]
    }

    resources = [
      aws_s3_bucket.stock_logos.arn,
      "${aws_s3_bucket.stock_logos.arn}/*",
    ]

    condition {
      test     = "Bool"
      variable = "aws:SecureTransport"
      values   = ["false"]
    }
  }
}

resource "aws_s3_bucket_policy" "stock_logos" {
  bucket = aws_s3_bucket.stock_logos.id
  policy = data.aws_iam_policy_document.stock_logos.json

  depends_on = [aws_s3_bucket_public_access_block.stock_logos]
}
