data "aws_caller_identity" "current" {}

data "aws_partition" "current" {}

locals {
  account_id = data.aws_caller_identity.current.account_id
  partition  = data.aws_partition.current.partition

  profile_image_bucket_name = "stockspoon-profile-images-${local.account_id}"
  profile_image_bucket_arn  = "arn:${local.partition}:s3:::${local.profile_image_bucket_name}"
  profile_image_key_prefix  = "profile-images/"

  # ECS Task가 읽을 수 있는 SSM 파라미터 범위 (예: /stockspoon/v2/prod/backend/DB_PASSWORD)
  ssm_parameter_arn_glob = "arn:${local.partition}:ssm:${var.aws_region}:${local.account_id}:parameter${var.ssm_parameter_path_prefix}/*"
}
