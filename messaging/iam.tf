data "aws_iam_policy_document" "backend_sqs" {
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

resource "aws_iam_policy" "backend_sqs" {
  name        = "${local.name_prefix}-backend-sqs"
  description = "Allows the V2 ${var.environment} Backend to publish report and order requests and consume orders"
  policy      = data.aws_iam_policy_document.backend_sqs.json

  tags = {
    Name = "${local.name_prefix}-backend-sqs"
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
