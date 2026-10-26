data "aws_caller_identity" "current" {}
data "aws_partition" "current" {}

locals {
  stock_logo_bucket_name = "stockspoon-stock-logos-${data.aws_caller_identity.current.account_id}"
  stock_logo_bucket_arn  = "arn:${data.aws_partition.current.partition}:s3:::${local.stock_logo_bucket_name}"
}

data "aws_iam_policy_document" "stock_logo_reader_writer" {
  statement {
    sid    = "ListStockLogoBucket"
    effect = "Allow"
    actions = [
      "s3:GetBucketLocation",
      "s3:ListBucket",
      "s3:ListBucketVersions",
    ]
    resources = [local.stock_logo_bucket_arn]
  }

  statement {
    sid    = "ReadAndWriteStockLogoObjects"
    effect = "Allow"
    actions = [
      "s3:GetObject",
      "s3:GetObjectVersion",
      "s3:PutObject",
    ]
    resources = ["${local.stock_logo_bucket_arn}/*"]
  }
}

resource "aws_iam_policy" "stock_logo_reader_writer" {
  name        = "stockspoon-stock-logo-reader-writer"
  description = "List, read, upload, and overwrite objects in the private StockSpoon stock logo bucket"
  policy      = data.aws_iam_policy_document.stock_logo_reader_writer.json

  tags = {
    Project   = "stockspoon"
    ManagedBy = "Terraform"
  }
}

resource "aws_iam_user_policy_attachment" "ezra_stock_logo_reader_writer" {
  user       = aws_iam_user.existing["ezra"].name
  policy_arn = aws_iam_policy.stock_logo_reader_writer.arn
}
