output "stock_logo_bucket_name" {
  description = "Private S3 bucket that stores stock logo objects"
  value       = aws_s3_bucket.stock_logos.id
}

output "stock_logo_bucket_arn" {
  description = "ARN of the private stock logo S3 bucket"
  value       = aws_s3_bucket.stock_logos.arn
}
