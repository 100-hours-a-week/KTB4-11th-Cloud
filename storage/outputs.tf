output "stock_logo_bucket_name" {
  description = "Private S3 bucket that stores stock logo objects"
  value       = aws_s3_bucket.stock_logos.id
}

output "stock_logo_bucket_arn" {
  description = "ARN of the private stock logo S3 bucket"
  value       = aws_s3_bucket.stock_logos.arn
}

output "profile_image_bucket_name" {
  description = "S3 bucket that stores public-read profile image objects"
  value       = aws_s3_bucket.profile_images.id
}

output "profile_image_bucket_arn" {
  description = "ARN of the profile image S3 bucket"
  value       = aws_s3_bucket.profile_images.arn
}

output "profile_image_key_prefix" {
  description = "Object key prefix reserved for profile images"
  value       = local.profile_image_key_prefix
}

output "profile_image_public_base_url" {
  description = "Public HTTPS URL prefix for profile image objects"
  value       = "https://${aws_s3_bucket.profile_images.bucket_regional_domain_name}/${local.profile_image_key_prefix}"
}
