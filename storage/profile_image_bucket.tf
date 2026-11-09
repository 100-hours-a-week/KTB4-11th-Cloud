locals {
  profile_image_bucket_name = "stockspoon-profile-images-${data.aws_caller_identity.current.account_id}"
  profile_image_key_prefix  = "profile-images/"
}

# Kakao profile images are served directly to app users; only reads are public.
resource "aws_s3_bucket" "profile_images" {
  bucket        = local.profile_image_bucket_name
  force_destroy = false

  tags = {
    Name        = local.profile_image_bucket_name
    Project     = "stockspoon"
    Environment = "shared"
    ManagedBy   = "Terraform"
  }

  lifecycle {
    prevent_destroy = true
  }
}

resource "aws_s3_bucket_ownership_controls" "profile_images" {
  bucket = aws_s3_bucket.profile_images.id

  rule {
    object_ownership = "BucketOwnerEnforced"
  }
}

resource "aws_s3_bucket_public_access_block" "profile_images" {
  bucket = aws_s3_bucket.profile_images.id

  block_public_acls       = true
  block_public_policy     = false
  ignore_public_acls      = true
  restrict_public_buckets = false
}

resource "aws_s3_bucket_server_side_encryption_configuration" "profile_images" {
  bucket = aws_s3_bucket.profile_images.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

data "aws_iam_policy_document" "profile_images" {
  statement {
    sid     = "AllowPublicReadOfProfileImages"
    effect  = "Allow"
    actions = ["s3:GetObject"]

    principals {
      type        = "*"
      identifiers = ["*"]
    }

    resources = ["${aws_s3_bucket.profile_images.arn}/${local.profile_image_key_prefix}*"]
  }

  statement {
    sid       = "DenyInsecureTransport"
    effect    = "Deny"
    actions   = ["s3:*"]
    resources = [aws_s3_bucket.profile_images.arn, "${aws_s3_bucket.profile_images.arn}/*"]

    principals {
      type        = "*"
      identifiers = ["*"]
    }

    condition {
      test     = "Bool"
      variable = "aws:SecureTransport"
      values   = ["false"]
    }
  }
}

resource "aws_s3_bucket_policy" "profile_images" {
  bucket = aws_s3_bucket.profile_images.id
  policy = data.aws_iam_policy_document.profile_images.json

  depends_on = [aws_s3_bucket_public_access_block.profile_images]
}
