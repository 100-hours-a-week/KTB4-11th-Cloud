# BE -> AI battle setup requests. Ordering is not required.
resource "aws_sqs_queue" "ai_request_dlq" {
  name                      = "${local.name_prefix}-ai-request-dlq"
  message_retention_seconds = 1209600
  sqs_managed_sse_enabled   = true
}

resource "aws_sqs_queue" "ai_request" {
  name                       = "${local.name_prefix}-ai-request"
  fifo_queue                 = false
  message_retention_seconds  = 345600
  receive_wait_time_seconds  = 20
  visibility_timeout_seconds = 300
  sqs_managed_sse_enabled    = true

  redrive_policy = jsonencode({
    deadLetterTargetArn = aws_sqs_queue.ai_request_dlq.arn
    maxReceiveCount     = 3
  })
}

resource "aws_sqs_queue_redrive_allow_policy" "ai_request_dlq" {
  queue_url = aws_sqs_queue.ai_request_dlq.id
  redrive_allow_policy = jsonencode({
    redrivePermission = "byQueue"
    sourceQueueArns   = [aws_sqs_queue.ai_request.arn]
  })
}
