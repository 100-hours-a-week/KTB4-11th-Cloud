data "aws_caller_identity" "current" {}

data "aws_partition" "current" {}

resource "aws_secretsmanager_secret" "discord_webhook" {
  name        = local.discord_webhook_secret_name
  description = "Discord webhook URL for StockSpoon V2 ${var.environment} Valkey alarms"

  tags = {
    Name = "${local.name_prefix}-discord-webhook"
  }
}

data "aws_iam_policy_document" "discord_notifier_assume_role" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["lambda.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "discord_notifier" {
  name               = "${local.discord_notifier_name}-role"
  assume_role_policy = data.aws_iam_policy_document.discord_notifier_assume_role.json

  tags = {
    Name = "${local.discord_notifier_name}-role"
  }
}

resource "aws_cloudwatch_log_group" "discord_notifier" {
  name              = "/aws/lambda/${local.discord_notifier_name}"
  retention_in_days = 14

  tags = {
    Name = "${local.discord_notifier_name}-logs"
  }
}

data "aws_iam_policy_document" "discord_notifier" {
  statement {
    sid       = "ReadDiscordWebhookSecret"
    effect    = "Allow"
    actions   = ["secretsmanager:GetSecretValue"]
    resources = [aws_secretsmanager_secret.discord_webhook.arn]
  }

  statement {
    sid    = "WriteNotifierLogs"
    effect = "Allow"
    actions = [
      "logs:CreateLogStream",
      "logs:PutLogEvents",
    ]
    resources = ["${aws_cloudwatch_log_group.discord_notifier.arn}:*"]
  }
}

resource "aws_iam_role_policy" "discord_notifier" {
  name   = "${local.discord_notifier_name}-policy"
  role   = aws_iam_role.discord_notifier.id
  policy = data.aws_iam_policy_document.discord_notifier.json
}

data "archive_file" "discord_notifier" {
  type        = "zip"
  source_file = "${path.module}/lambda/valkey_discord_notifier.py"
  output_path = "${path.module}/.terraform/valkey_discord_notifier.zip"
}

resource "aws_lambda_function" "discord_notifier" {
  function_name    = local.discord_notifier_name
  description      = "Sends StockSpoon V2 ${var.environment} Valkey alarm notifications to Discord"
  role             = aws_iam_role.discord_notifier.arn
  runtime          = "python3.12"
  handler          = "valkey_discord_notifier.handler"
  filename         = data.archive_file.discord_notifier.output_path
  source_code_hash = data.archive_file.discord_notifier.output_base64sha256
  timeout          = 15
  memory_size      = 128

  environment {
    variables = {
      DISCORD_WEBHOOK_SECRET_ARN = aws_secretsmanager_secret.discord_webhook.arn
    }
  }

  depends_on = [
    aws_iam_role_policy.discord_notifier,
    aws_cloudwatch_log_group.discord_notifier,
  ]

  tags = {
    Name = local.discord_notifier_name
  }
}
