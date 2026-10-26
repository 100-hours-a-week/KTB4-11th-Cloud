data "aws_caller_identity" "current" {}

locals {
  stock_logo_bucket_name = "stockspoon-stock-logos-${data.aws_caller_identity.current.account_id}"
}

# 주식 로고 원본 저장소. 객체 조회만 공개하고 변경은 IAM 권한으로 제한한다.
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
  block_public_policy     = false
  ignore_public_acls      = true
  restrict_public_buckets = false
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
    sid     = "AllowPublicRead"
    effect  = "Allow"
    actions = ["s3:GetObject"]

    principals {
      type        = "*"
      identifiers = ["*"]
    }

    resources = ["${aws_s3_bucket.stock_logos.arn}/*"]
  }

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
