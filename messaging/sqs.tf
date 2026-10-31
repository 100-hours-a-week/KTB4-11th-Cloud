resource "aws_sqs_queue" "report_dlq" {
  name                      = "${local.name_prefix}-report-dlq"
  message_retention_seconds = 1209600
  receive_wait_time_seconds = 20
  sqs_managed_sse_enabled   = true

  tags = {
    Name = "${local.name_prefix}-report-dlq"
  }
}

resource "aws_sqs_queue" "report_request" {
  name                       = "${local.name_prefix}-report-request"
  message_retention_seconds  = 345600
  receive_wait_time_seconds  = 20
  visibility_timeout_seconds = 300
  sqs_managed_sse_enabled    = true

  redrive_policy = jsonencode({
    deadLetterTargetArn = aws_sqs_queue.report_dlq.arn
    maxReceiveCount     = 3
  })

  tags = {
    Name = "${local.name_prefix}-report-request"
  }
}

resource "aws_sqs_queue_redrive_allow_policy" "report_dlq" {
  queue_url = aws_sqs_queue.report_dlq.id

  redrive_allow_policy = jsonencode({
    redrivePermission = "byQueue"
    sourceQueueArns   = [aws_sqs_queue.report_request.arn]
  })
}

resource "aws_sqs_queue" "order_dlq" {
  name                        = "${local.name_prefix}-order-dlq.fifo"
  fifo_queue                  = true
  content_based_deduplication = false
  message_retention_seconds   = 1209600
  receive_wait_time_seconds   = 20
  sqs_managed_sse_enabled     = true

  tags = {
    Name = "${local.name_prefix}-order-dlq.fifo"
  }
}

resource "aws_sqs_queue" "order" {
  name                        = "${local.name_prefix}-order.fifo"
  fifo_queue                  = true
  content_based_deduplication = false
  message_retention_seconds   = 345600
  receive_wait_time_seconds   = 20
  visibility_timeout_seconds  = 60
  sqs_managed_sse_enabled     = true

  redrive_policy = jsonencode({
    deadLetterTargetArn = aws_sqs_queue.order_dlq.arn
    maxReceiveCount     = 3
  })

  tags = {
    Name = "${local.name_prefix}-order.fifo"
  }
}

resource "aws_sqs_queue_redrive_allow_policy" "order_dlq" {
  queue_url = aws_sqs_queue.order_dlq.id

  redrive_allow_policy = jsonencode({
    redrivePermission = "byQueue"
    sourceQueueArns   = [aws_sqs_queue.order.arn]
  })
}
