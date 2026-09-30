locals {
  app_discord_webhook_secret_name = "stockspoon/v1/app/discord-webhook"
  app_discord_lambda_name         = "stockspoon-v1-app-discord-notifier"
  app_discord_lambda_log_group    = "/aws/lambda/${local.app_discord_lambda_name}"
  app_alert_ses_domain            = "notify.${trimsuffix(var.route53_zone_name, ".")}"
  app_alert_email_from            = "cloudwatch-alerts@${local.app_alert_ses_domain}"
}

data "aws_route53_zone" "app_alert_email" {
  name         = local.app_route53_zone_fqdn
  private_zone = false
}

# The webhook value is deliberately not managed by Terraform, so it is not
# written into Terraform state. Store a rotated webhook in this secret after
# the first apply and before enabling alarm actions.
resource "aws_secretsmanager_secret" "app_discord_webhook" {
  name        = local.app_discord_webhook_secret_name
  description = "Incoming Discord webhook URL used for Stockspoon application alarms"

  tags = {
    Name        = "stockspoon-v1-app-discord-webhook"
    Project     = "stockspoon"
    Environment = "v1"
    ManagedBy   = "Terraform"
  }
}

# Use a dedicated mail subdomain so SES verification/DKIM records do not
# replace records on the root domain or interfere with its other senders.
resource "aws_ses_domain_identity" "app_alert_email" {
  domain = local.app_alert_ses_domain
}

resource "aws_route53_record" "app_alert_email_verification" {
  zone_id = data.aws_route53_zone.app_alert_email.zone_id
  name    = "_amazonses.${local.app_alert_ses_domain}"
  type    = "TXT"
  ttl     = 600
  records = [aws_ses_domain_identity.app_alert_email.verification_token]
}

resource "aws_ses_domain_identity_verification" "app_alert_email" {
  domain     = aws_ses_domain_identity.app_alert_email.domain
  depends_on = [aws_route53_record.app_alert_email_verification]
}

resource "aws_ses_domain_dkim" "app_alert_email" {
  domain     = aws_ses_domain_identity.app_alert_email.domain
  depends_on = [aws_ses_domain_identity_verification.app_alert_email]
}

resource "aws_route53_record" "app_alert_email_dkim" {
  count   = 3
  zone_id = data.aws_route53_zone.app_alert_email.zone_id
  name    = "${aws_ses_domain_dkim.app_alert_email.dkim_tokens[count.index]}._domainkey.${local.app_alert_ses_domain}"
  type    = "CNAME"
  ttl     = 600
  records = ["${aws_ses_domain_dkim.app_alert_email.dkim_tokens[count.index]}.dkim.amazonses.com"]
}

# If SES is still in its sandbox, the recipient must confirm this identity
# before alarm emails can be delivered.
resource "aws_ses_email_identity" "app_alert_recipient" {
  email = var.app_alert_email_recipient
}

data "aws_iam_policy_document" "app_discord_lambda_assume_role" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["lambda.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "app_discord_lambda" {
  name               = "stockspoon-v1-app-discord-notifier-role"
  assume_role_policy = data.aws_iam_policy_document.app_discord_lambda_assume_role.json

  tags = {
    Name        = "stockspoon-v1-app-discord-notifier-role"
    Project     = "stockspoon"
    Environment = "v1"
    ManagedBy   = "Terraform"
  }
}

data "aws_iam_policy_document" "app_discord_lambda" {
  statement {
    sid       = "ReadDiscordWebhookSecret"
    effect    = "Allow"
    actions   = ["secretsmanager:GetSecretValue"]
    resources = [aws_secretsmanager_secret.app_discord_webhook.arn]
  }

  statement {
    sid       = "SendAlarmEmail"
    effect    = "Allow"
    actions   = ["ses:SendEmail"]
    resources = [aws_ses_domain_identity.app_alert_email.arn]
  }

  statement {
    sid    = "WriteDiscordNotifierLogs"
    effect = "Allow"
    actions = [
      "logs:CreateLogStream",
      "logs:PutLogEvents",
    ]
    resources = ["${aws_cloudwatch_log_group.app_discord_lambda.arn}:*"]
  }
}

resource "aws_iam_role_policy" "app_discord_lambda" {
  name   = "stockspoon-v1-app-discord-notifier-policy"
  role   = aws_iam_role.app_discord_lambda.id
  policy = data.aws_iam_policy_document.app_discord_lambda.json
}

resource "aws_cloudwatch_log_group" "app_discord_lambda" {
  name              = local.app_discord_lambda_log_group
  retention_in_days = 14

  tags = {
    Name        = "stockspoon-v1-app-discord-notifier-logs"
    Project     = "stockspoon"
    Environment = "v1"
    ManagedBy   = "Terraform"
  }
}

resource "aws_lambda_function" "app_discord_notifier" {
  function_name    = local.app_discord_lambda_name
  description      = "Sends Stockspoon CloudWatch alarm notifications to Discord and email through SES"
  role             = aws_iam_role.app_discord_lambda.arn
  runtime          = "python3.12"
  handler          = "discord_notifier.handler"
  filename         = "${path.module}/lambda/discord_notifier.zip"
  source_code_hash = filebase64sha256("${path.module}/lambda/discord_notifier.zip")
  timeout          = 20
  memory_size      = 128

  environment {
    variables = {
      DISCORD_WEBHOOK_SECRET_ARN = aws_secretsmanager_secret.app_discord_webhook.arn
      SES_FROM_EMAIL             = local.app_alert_email_from
      ALERT_EMAIL_RECIPIENT      = var.app_alert_email_recipient
    }
  }

  depends_on = [
    aws_iam_role_policy.app_discord_lambda,
    aws_ses_domain_identity_verification.app_alert_email,
    aws_route53_record.app_alert_email_dkim,
  ]

  tags = {
    Name        = local.app_discord_lambda_name
    Project     = "stockspoon"
    Environment = "v1"
    ManagedBy   = "Terraform"
  }
}

# CloudWatch alarms invoke Lambda directly. Restrict invocation to this AWS
# account and the Stockspoon V1 application alarm-name prefix.
resource "aws_lambda_permission" "app_cloudwatch_alarms" {
  statement_id   = "AllowStockspoonAppCloudWatchAlarms"
  action         = "lambda:InvokeFunction"
  function_name  = aws_lambda_function.app_discord_notifier.function_name
  principal      = "lambda.alarms.cloudwatch.amazonaws.com"
  source_account = data.aws_caller_identity.monitoring.account_id
  source_arn     = "arn:${data.aws_partition.monitoring.partition}:cloudwatch:${var.aws_region}:${data.aws_caller_identity.monitoring.account_id}:alarm:stockspoon-v1-app-*"
}
