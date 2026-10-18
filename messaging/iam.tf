data "aws_iam_policy_document" "backend_producer_sqs" {
  statement {
    sid       = "SendReportRequests"
    effect    = "Allow"
    actions   = ["sqs:SendMessage"]
    resources = [aws_sqs_queue.report_request.arn]
  }

  statement {
    sid       = "SendOrders"
    effect    = "Allow"
    actions   = ["sqs:SendMessage"]
    resources = [aws_sqs_queue.order.arn]
  }

}

resource "aws_iam_policy" "backend_producer_sqs" {
  name        = "${local.name_prefix}-backend-producer-sqs"
  description = "Allows the V2 ${var.environment} Backend API to publish report and order requests"
  policy      = data.aws_iam_policy_document.backend_producer_sqs.json

  tags = {
    Name = "${local.name_prefix}-backend-producer-sqs"
  }
}

data "aws_iam_policy_document" "order_consumer_sqs" {
  statement {
    sid    = "ConsumeOrders"
    effect = "Allow"
    actions = [
      "sqs:ReceiveMessage",
      "sqs:DeleteMessage",
      "sqs:ChangeMessageVisibility",
      "sqs:GetQueueAttributes",
    ]
    resources = [aws_sqs_queue.order.arn]
  }
}

resource "aws_iam_policy" "order_consumer_sqs" {
  name        = "${local.name_prefix}-order-consumer-sqs"
  description = "Allows the V2 ${var.environment} order consumer to process order requests"
  policy      = data.aws_iam_policy_document.order_consumer_sqs.json

  tags = {
    Name = "${local.name_prefix}-order-consumer-sqs"
  }
}

data "aws_iam_policy_document" "ai_sqs" {
  statement {
    sid       = "SendOrders"
    effect    = "Allow"
    actions   = ["sqs:SendMessage"]
    resources = [aws_sqs_queue.order.arn]
  }

  statement {
    sid    = "ConsumeReportRequests"
    effect = "Allow"
    actions = [
      "sqs:ReceiveMessage",
      "sqs:DeleteMessage",
      "sqs:ChangeMessageVisibility",
      "sqs:GetQueueAttributes",
    ]
    resources = [aws_sqs_queue.report_request.arn]
  }
}

resource "aws_iam_policy" "ai_sqs" {
  name        = "${local.name_prefix}-ai-sqs"
  description = "Allows the V2 ${var.environment} AI service to publish orders and consume report requests"
  policy      = data.aws_iam_policy_document.ai_sqs.json

  tags = {
    Name = "${local.name_prefix}-ai-sqs"
  }
}

data "aws_iam_policy_document" "backend_db_write_replay_producer" {
  statement {
    sid       = "SendDatabaseWriteReplayMessages"
    effect    = "Allow"
    actions   = ["sqs:SendMessage"]
    resources = [aws_sqs_queue.db_write_replay.arn]
  }
}

resource "aws_iam_policy" "backend_db_write_replay_producer" {
  name        = "${local.name_prefix}-backend-db-write-replay-producer"
  description = "Allows the V2 ${var.environment} Backend to enqueue failed database writes"
  policy      = data.aws_iam_policy_document.backend_db_write_replay_producer.json

  tags = {
    Name = "${local.name_prefix}-backend-db-write-replay-producer"
  }
}

data "aws_iam_policy_document" "db_write_replay_consumer" {
  statement {
    sid    = "ConsumeDatabaseWriteReplayMessages"
    effect = "Allow"
    actions = [
      "sqs:ReceiveMessage",
      "sqs:DeleteMessage",
      "sqs:ChangeMessageVisibility",
      "sqs:GetQueueAttributes",
    ]
    resources = [aws_sqs_queue.db_write_replay.arn]
  }
}

resource "aws_iam_policy" "db_write_replay_consumer" {
  name        = "${local.name_prefix}-db-write-replay-consumer"
  description = "Allows the DB write replay Lambda to receive and acknowledge queued writes"
  policy      = data.aws_iam_policy_document.db_write_replay_consumer.json

  tags = {
    Name = "${local.name_prefix}-db-write-replay-consumer"
  }
}
