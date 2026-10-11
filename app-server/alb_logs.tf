# ALB Access Log 저장소
# Nginx까지 도달하지 못하고 ALB에서 끝난 요청(5xx, 연결 실패 등)을 추적하는 데 사용

data "aws_caller_identity" "current" {}

data "aws_elb_service_account" "current" {}

locals {
  alb_access_log_bucket_name = "stockspoon-v1-alb-logs-${data.aws_caller_identity.current.account_id}"
  alb_access_log_bucket_arn  = "arn:${data.aws_partition.github_actions_terraform.partition}:s3:::${local.alb_access_log_bucket_name}"
  alb_access_log_prefix      = "alb"
}

resource "aws_s3_bucket" "alb_logs" {
  bucket = local.alb_access_log_bucket_name

  tags = {
    Name        = local.alb_access_log_bucket_name
    Project     = "stockspoon"
    Environment = "v1"
    ManagedBy   = "Terraform"
  }
}

resource "aws_s3_bucket_public_access_block" "alb_logs" {
  bucket = aws_s3_bucket.alb_logs.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_server_side_encryption_configuration" "alb_logs" {
  bucket = aws_s3_bucket.alb_logs.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256" # ALB Access Log는 SSE-S3(AES256)만 지원
    }
  }
}

resource "aws_s3_bucket_lifecycle_configuration" "alb_logs" {
  bucket = aws_s3_bucket.alb_logs.id

  rule {
    id     = "expire-alb-access-logs"
    status = "Enabled"

    filter {}

    expiration {
      days = var.alb_access_log_retention_days
    }
  }
}

data "aws_iam_policy_document" "alb_logs" {
  statement {
    sid     = "AllowElbAccessLogDelivery"
    effect  = "Allow"
    actions = ["s3:PutObject"]

    principals {
      type        = "AWS"
      identifiers = [data.aws_elb_service_account.current.arn]
    }

    resources = [
      "${aws_s3_bucket.alb_logs.arn}/${local.alb_access_log_prefix}/AWSLogs/${data.aws_caller_identity.current.account_id}/*",
    ]
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
      aws_s3_bucket.alb_logs.arn,
      "${aws_s3_bucket.alb_logs.arn}/*",
    ]

    condition {
      test     = "Bool"
      variable = "aws:SecureTransport"
      values   = ["false"]
    }
  }
}

resource "aws_s3_bucket_policy" "alb_logs" {
  bucket = aws_s3_bucket.alb_logs.id
  policy = data.aws_iam_policy_document.alb_logs.json

  # Public Access Block이 먼저 적용된 뒤 정책을 넣는다.
  depends_on = [aws_s3_bucket_public_access_block.alb_logs]
}

output "alb_access_log_bucket" {
  description = "S3 bucket and prefix that receive ALB access logs"
  value       = "${aws_s3_bucket.alb_logs.bucket}/${local.alb_access_log_prefix}"
}
