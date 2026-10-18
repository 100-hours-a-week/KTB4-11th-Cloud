locals {
  db_write_replay_consumer_name = "${local.name_prefix}-db-write-replay-forwarder"
  db_write_replay_token_secret  = "${var.project_name}/v2/${var.environment}/db-write-replay/consumer-token"
}

resource "aws_secretsmanager_secret" "db_write_replay_token" {
  name        = local.db_write_replay_token_secret
  description = "Bearer token shared by the DB write replay Lambda and Backend endpoint"

  tags = {
    Name = "${local.name_prefix}-db-write-replay-token"
  }
}

data "aws_iam_policy_document" "db_write_replay_forwarder_assume_role" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["lambda.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "db_write_replay_forwarder" {
  name               = "${local.db_write_replay_consumer_name}-role"
  assume_role_policy = data.aws_iam_policy_document.db_write_replay_forwarder_assume_role.json

  tags = {
    Name = "${local.db_write_replay_consumer_name}-role"
  }
}

resource "aws_cloudwatch_log_group" "db_write_replay_forwarder" {
  name              = "/aws/lambda/${local.db_write_replay_consumer_name}"
  retention_in_days = 14

  tags = {
    Name = "${local.db_write_replay_consumer_name}-logs"
  }
}

data "aws_iam_policy_document" "db_write_replay_forwarder" {
  statement {
    sid       = "ReadReplayEndpointToken"
    effect    = "Allow"
    actions   = ["secretsmanager:GetSecretValue"]
    resources = [aws_secretsmanager_secret.db_write_replay_token.arn]
  }

  statement {
    sid    = "WriteForwarderLogs"
    effect = "Allow"
    actions = [
      "logs:CreateLogStream",
      "logs:PutLogEvents",
    ]
    resources = ["${aws_cloudwatch_log_group.db_write_replay_forwarder.arn}:*"]
  }
}

resource "aws_iam_role_policy" "db_write_replay_forwarder" {
  name   = "${local.db_write_replay_consumer_name}-policy"
  role   = aws_iam_role.db_write_replay_forwarder.id
  policy = data.aws_iam_policy_document.db_write_replay_forwarder.json
}

resource "aws_iam_role_policy_attachment" "db_write_replay_forwarder_sqs" {
  role       = aws_iam_role.db_write_replay_forwarder.name
  policy_arn = aws_iam_policy.db_write_replay_consumer.arn
}

data "archive_file" "db_write_replay_forwarder" {
  type        = "zip"
  source_file = "${path.module}/lambda/db_write_replay_forwarder.py"
  output_path = "${path.module}/.terraform/db_write_replay_forwarder.zip"
}

resource "aws_lambda_function" "db_write_replay_forwarder" {
  function_name                  = local.db_write_replay_consumer_name
  description                    = "Forwards FIFO DB write replay messages to the authenticated Backend replay endpoint"
  role                           = aws_iam_role.db_write_replay_forwarder.arn
  runtime                        = "python3.12"
  handler                        = "db_write_replay_forwarder.handler"
  filename                       = data.archive_file.db_write_replay_forwarder.output_path
  source_code_hash               = data.archive_file.db_write_replay_forwarder.output_base64sha256
  timeout                        = 30
  memory_size                    = 128
  reserved_concurrent_executions = 1

  environment {
    variables = {
      DB_WRITE_REPLAY_ENDPOINT_URL         = var.db_write_replay_endpoint_url
      DB_WRITE_REPLAY_TOKEN_SECRET_ARN     = aws_secretsmanager_secret.db_write_replay_token.arn
      DB_WRITE_REPLAY_HTTP_TIMEOUT_SECONDS = "20"
    }
  }

  depends_on = [
    aws_iam_role_policy.db_write_replay_forwarder,
    aws_iam_role_policy_attachment.db_write_replay_forwarder_sqs,
    aws_cloudwatch_log_group.db_write_replay_forwarder,
  ]

  tags = {
    Name = local.db_write_replay_consumer_name
  }
}

# Keep the event source mapping disabled until the Backend has deployed an
# authenticated, idempotent replay endpoint and its HTTPS URL/token are set.
resource "aws_lambda_event_source_mapping" "db_write_replay_forwarder" {
  event_source_arn = aws_sqs_queue.db_write_replay.arn
  function_name    = aws_lambda_function.db_write_replay_forwarder.arn
  enabled          = var.db_write_replay_consumer_enabled
  batch_size       = 1

  lifecycle {
    precondition {
      condition = !var.db_write_replay_consumer_enabled || (
        length(trimspace(var.db_write_replay_endpoint_url)) > 0 &&
        can(regex("^https://", var.db_write_replay_endpoint_url))
      )
      error_message = "Enable the DB write replay consumer only after setting an HTTPS Backend replay endpoint URL."
    }
  }
}
