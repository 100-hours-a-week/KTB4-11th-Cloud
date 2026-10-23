data "aws_iam_policy_document" "telemetry_assume_role" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "telemetry" {
  count              = var.plg_tempo_enabled ? 1 : 0
  name               = local.telemetry_name
  assume_role_policy = data.aws_iam_policy_document.telemetry_assume_role.json
}

resource "aws_iam_role_policy_attachment" "telemetry_ssm" {
  count      = var.plg_tempo_enabled ? 1 : 0
  role       = aws_iam_role.telemetry[0].name
  policy_arn = "arn:${local.partition}:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_role_policy" "telemetry_storage" {
  count = var.plg_tempo_enabled ? 1 : 0
  name  = "telemetry-storage"
  role  = aws_iam_role.telemetry[0].id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = ["s3:ListBucket", "s3:GetBucketLocation"]
        Resource = [for bucket in aws_s3_bucket.telemetry : bucket.arn]
      },
      {
        Effect   = "Allow"
        Action   = ["s3:GetObject", "s3:PutObject", "s3:DeleteObject", "s3:AbortMultipartUpload", "s3:ListMultipartUploadParts"]
        Resource = [for bucket in aws_s3_bucket.telemetry : "${bucket.arn}/*"]
      }
    ]
  })
}

resource "aws_iam_instance_profile" "telemetry" {
  count = var.plg_tempo_enabled ? 1 : 0
  name  = local.telemetry_name
  role  = aws_iam_role.telemetry[0].name
}

data "aws_secretsmanager_secret" "discord" {
  count = var.plg_tempo_enabled ? 1 : 0
  name  = "stockspoon/v1/app/discord-webhook"
}

resource "aws_iam_role_policy" "telemetry_discord" {
  count = var.plg_tempo_enabled ? 1 : 0
  name  = "telemetry-discord-webhook-read"
  role  = aws_iam_role.telemetry[0].id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = ["secretsmanager:GetSecretValue"]
        Resource = data.aws_secretsmanager_secret.discord[0].arn
      },
      {
        Effect = "Allow"
        Action = ["ssm:GetParameter"]
        Resource = concat(
          [for parameter in aws_ssm_parameter.development_discord_webhook : parameter.arn],
          [for parameter in aws_ssm_parameter.production_discord_webhook : parameter.arn],
        )
      }
    ]
  })
}
