locals {
  ai_discord_webhook_secret_name = "stockspoon/v1/ai/discord-webhook"
  ai_discord_lambda_name         = "stockspoon-v1-ai-discord-notifier"
  ai_discord_lambda_log_group    = "/aws/lambda/${local.ai_discord_lambda_name}"
}

# Webhook 값은 Terraform state에 남기지 않습니다. 최초 apply 후 콘솔 또는
# CLI를 통해 이 Secret에 새 Discord Webhook URL을 직접 저장해야 합니다.
resource "aws_secretsmanager_secret" "ai_discord_webhook" {
  name        = local.ai_discord_webhook_secret_name
  description = "Incoming Discord webhook URL used for Stockspoon AI alarms"

  tags = merge(local.ai_alarm_tags, {
    Name = "stockspoon-v1-ai-discord-webhook"
  })
}

data "aws_iam_policy_document" "ai_discord_lambda_assume_role" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["lambda.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "ai_discord_lambda" {
  name               = "stockspoon-v1-ai-discord-notifier-role"
  assume_role_policy = data.aws_iam_policy_document.ai_discord_lambda_assume_role.json

  tags = merge(local.ai_alarm_tags, {
    Name = "stockspoon-v1-ai-discord-notifier-role"
  })
}

data "aws_iam_policy_document" "ai_discord_lambda" {
  statement {
    sid       = "ReadAIDiscordWebhookSecret"
    effect    = "Allow"
    actions   = ["secretsmanager:GetSecretValue"]
    resources = [aws_secretsmanager_secret.ai_discord_webhook.arn]
  }

  statement {
    sid     = "RunAIDockerStatsCommand"
    effect  = "Allow"
    actions = ["ssm:SendCommand"]
    resources = [
      "arn:${data.aws_partition.current.partition}:ssm:${var.aws_region}::document/AWS-RunShellScript",
      "arn:${data.aws_partition.current.partition}:ec2:${var.aws_region}:${data.aws_caller_identity.current.account_id}:instance/${var.ai_instance_id}",
    ]
  }

  statement {
    sid       = "ReadAIDockerStatsCommand"
    effect    = "Allow"
    actions   = ["ssm:GetCommandInvocation"]
    resources = ["*"]
  }

  statement {
    sid    = "WriteAIDiscordNotifierLogs"
    effect = "Allow"
    actions = [
      "logs:CreateLogStream",
      "logs:PutLogEvents",
    ]
    resources = ["${aws_cloudwatch_log_group.ai_discord_lambda.arn}:*"]
  }
}

resource "aws_iam_role_policy" "ai_discord_lambda" {
  name   = "stockspoon-v1-ai-discord-notifier-policy"
  role   = aws_iam_role.ai_discord_lambda.id
  policy = data.aws_iam_policy_document.ai_discord_lambda.json
}

resource "aws_cloudwatch_log_group" "ai_discord_lambda" {
  name              = local.ai_discord_lambda_log_group
  retention_in_days = 14

  tags = merge(local.ai_alarm_tags, {
    Name = "stockspoon-v1-ai-discord-notifier-logs"
  })
}

resource "aws_lambda_function" "ai_discord_notifier" {
  function_name    = local.ai_discord_lambda_name
  description      = "Sends Stockspoon AI CloudWatch alarm notifications to Discord"
  role             = aws_iam_role.ai_discord_lambda.arn
  runtime          = "python3.12"
  handler          = "ai_discord_notifier.handler"
  filename         = "${path.module}/lambda/ai_discord_notifier.zip"
  source_code_hash = filebase64sha256("${path.module}/lambda/ai_discord_notifier.zip")
  timeout          = 30
  memory_size      = 128

  environment {
    variables = {
      DISCORD_WEBHOOK_SECRET_ARN = aws_secretsmanager_secret.ai_discord_webhook.arn
      AI_INSTANCE_ID             = var.ai_instance_id
    }
  }

  depends_on = [aws_iam_role_policy.ai_discord_lambda]

  tags = merge(local.ai_alarm_tags, {
    Name = local.ai_discord_lambda_name
  })
}
