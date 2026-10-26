resource "aws_s3_bucket" "telemetry" {
  for_each = var.plg_tempo_enabled ? toset(["loki", "tempo"]) : toset([])
  bucket   = "${local.telemetry_name}-${each.key}-${local.account_id}-${var.aws_region}"

  lifecycle {
    prevent_destroy = true
  }
}

resource "aws_s3_bucket_public_access_block" "telemetry" {
  for_each                = aws_s3_bucket.telemetry
  bucket                  = each.value.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_server_side_encryption_configuration" "telemetry" {
  for_each = aws_s3_bucket.telemetry
  bucket   = each.value.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_policy" "telemetry_tls" {
  for_each = aws_s3_bucket.telemetry
  bucket   = each.value.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Deny"
      Principal = "*"
      Action    = "s3:*"
      Resource  = [each.value.arn, "${each.value.arn}/*"]
      Condition = { Bool = { "aws:SecureTransport" = "false" } }
    }]
  })
}
