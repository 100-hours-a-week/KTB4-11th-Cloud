data "aws_caller_identity" "messaging" {}

data "aws_partition" "messaging" {}

locals {
  sqs_alarm_prefix = "${local.name_prefix}-sqs"
}

resource "aws_cloudwatch_dashboard" "sqs" {
  dashboard_name = "${local.name_prefix}-sqs"

  dashboard_body = jsonencode({
    widgets = [
      {
        type   = "metric"
        x      = 0
        y      = 0
        width  = 12
        height = 6
        properties = {
          title   = "SQS backlog and in-flight messages"
          region  = var.aws_region
          view    = "timeSeries"
          stacked = false
          period  = 60
          stat    = "Maximum"
          metrics = [
            ["AWS/SQS", "ApproximateNumberOfMessagesVisible", "QueueName", aws_sqs_queue.report_request.name, { label = "Report visible" }],
            [".", "ApproximateNumberOfMessagesNotVisible", ".", ".", { label = "Report in flight" }],
            [".", "ApproximateNumberOfMessagesVisible", ".", aws_sqs_queue.order.name, { label = "Order visible" }],
            [".", "ApproximateNumberOfMessagesNotVisible", ".", ".", { label = "Order in flight" }],
          ]
        }
      },
      {
        type   = "metric"
        x      = 12
        y      = 0
        width  = 12
        height = 6
        properties = {
          title  = "SQS oldest message age"
          region = var.aws_region
          view   = "timeSeries"
          period = 60
          stat   = "Maximum"
          metrics = [
            ["AWS/SQS", "ApproximateAgeOfOldestMessage", "QueueName", aws_sqs_queue.report_request.name, { label = "Report oldest age" }],
            [".", ".", ".", aws_sqs_queue.order.name, { label = "Order oldest age" }],
          ]
        }
      },
      {
        type   = "metric"
        x      = 0
        y      = 6
        width  = 12
        height = 6
        properties = {
          title  = "Report queue throughput"
          region = var.aws_region
          view   = "timeSeries"
          period = 60
          stat   = "Sum"
          metrics = [
            ["AWS/SQS", "NumberOfMessagesSent", "QueueName", aws_sqs_queue.report_request.name, { label = "Sent" }],
            [".", "NumberOfMessagesDeleted", ".", ".", { label = "Deleted" }],
          ]
        }
      },
      {
        type   = "metric"
        x      = 12
        y      = 6
        width  = 12
        height = 6
        properties = {
          title  = "Order queue throughput"
          region = var.aws_region
          view   = "timeSeries"
          period = 60
          stat   = "Sum"
          metrics = [
            ["AWS/SQS", "NumberOfMessagesSent", "QueueName", aws_sqs_queue.order.name, { label = "Sent" }],
            [".", "NumberOfMessagesDeleted", ".", ".", { label = "Deleted" }],
          ]
        }
      },
    ]
  })
}

resource "aws_lambda_permission" "sqs_cloudwatch_alarms" {
  statement_id   = "AllowStockspoonV2${title(var.environment)}SqsCloudWatchAlarms"
  action         = "lambda:InvokeFunction"
  function_name  = aws_lambda_function.sqs_discord_notifier.function_name
  principal      = "lambda.alarms.cloudwatch.amazonaws.com"
  source_account = data.aws_caller_identity.messaging.account_id
  source_arn     = "arn:${data.aws_partition.messaging.partition}:cloudwatch:${var.aws_region}:${data.aws_caller_identity.messaging.account_id}:alarm:${local.sqs_alarm_prefix}-*"
}

resource "aws_cloudwatch_metric_alarm" "report_dlq_not_empty" {
  alarm_name          = "${local.sqs_alarm_prefix}-report-dlq-not-empty"
  alarm_description   = "The V2 ${var.environment} report DLQ contains at least one visible message."
  namespace           = "AWS/SQS"
  metric_name         = "ApproximateNumberOfMessagesVisible"
  statistic           = "Maximum"
  period              = 60
  evaluation_periods  = 1
  datapoints_to_alarm = 1
  threshold           = 1
  comparison_operator = "GreaterThanOrEqualToThreshold"
  treat_missing_data  = "notBreaching"
  alarm_actions       = [aws_lambda_function.sqs_discord_notifier.arn]
  ok_actions          = [aws_lambda_function.sqs_discord_notifier.arn]

  dimensions = {
    QueueName = aws_sqs_queue.report_dlq.name
  }

  depends_on = [aws_lambda_permission.sqs_cloudwatch_alarms]
}

resource "aws_cloudwatch_metric_alarm" "order_dlq_not_empty" {
  alarm_name          = "${local.sqs_alarm_prefix}-order-dlq-not-empty"
  alarm_description   = "The V2 ${var.environment} order DLQ contains at least one visible message."
  namespace           = "AWS/SQS"
  metric_name         = "ApproximateNumberOfMessagesVisible"
  statistic           = "Maximum"
  period              = 60
  evaluation_periods  = 1
  datapoints_to_alarm = 1
  threshold           = 1
  comparison_operator = "GreaterThanOrEqualToThreshold"
  treat_missing_data  = "notBreaching"
  alarm_actions       = [aws_lambda_function.sqs_discord_notifier.arn]
  ok_actions          = [aws_lambda_function.sqs_discord_notifier.arn]

  dimensions = {
    QueueName = aws_sqs_queue.order_dlq.name
  }

  depends_on = [aws_lambda_permission.sqs_cloudwatch_alarms]
}
