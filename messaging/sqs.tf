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

# 임시 복구: Backend replay 정책을 ECS 역할에서 분리하는 apply가 끝날 때까지 큐 상태를 유지한다.
resource "aws_sqs_queue" "db_write_replay_dlq" {
  name                        = "${local.name_prefix}-db-write-replay-dlq.fifo"
  fifo_queue                  = true
  content_based_deduplication = false
  message_retention_seconds   = 1209600
  receive_wait_time_seconds   = 20
  sqs_managed_sse_enabled     = true

  tags = {
    Name = "${local.name_prefix}-db-write-replay-dlq.fifo"
  }
}

resource "aws_sqs_queue" "db_write_replay" {
  name                        = "${local.name_prefix}-db-write-replay.fifo"
  fifo_queue                  = true
  content_based_deduplication = false
  message_retention_seconds   = 1209600
  receive_wait_time_seconds   = 20
  visibility_timeout_seconds  = 300
  sqs_managed_sse_enabled     = true

  redrive_policy = jsonencode({
    deadLetterTargetArn = aws_sqs_queue.db_write_replay_dlq.arn
    # This consumer is invoked manually and stops at the first failed message.
    # Keep transient ProxySQL/primary-switch failures from quickly moving the
    # FIFO head to the DLQ and exposing later writes first.
    maxReceiveCount = 1000
  })

  tags = {
    Name = "${local.name_prefix}-db-write-replay.fifo"
  }
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
