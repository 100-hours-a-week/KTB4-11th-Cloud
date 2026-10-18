output "report_queue_url" {
  description = "URL of the AI report request queue"
  value       = aws_sqs_queue.report_request.url
}

output "report_queue_arn" {
  description = "ARN of the AI report request queue"
  value       = aws_sqs_queue.report_request.arn
}

output "report_dlq_url" {
  description = "URL of the AI report dead-letter queue"
  value       = aws_sqs_queue.report_dlq.url
}

output "report_dlq_arn" {
  description = "ARN of the AI report dead-letter queue"
  value       = aws_sqs_queue.report_dlq.arn
}

output "order_queue_url" {
  description = "URL of the FIFO order queue"
  value       = aws_sqs_queue.order.url
}

output "order_queue_arn" {
  description = "ARN of the FIFO order queue"
  value       = aws_sqs_queue.order.arn
}

output "order_dlq_url" {
  description = "URL of the FIFO order dead-letter queue"
  value       = aws_sqs_queue.order_dlq.url
}

output "order_dlq_arn" {
  description = "ARN of the FIFO order dead-letter queue"
  value       = aws_sqs_queue.order_dlq.arn
}

output "db_write_replay_queue_url" {
  description = "URL of the FIFO queue for backend database writes rejected during primary switching"
  value       = aws_sqs_queue.db_write_replay.url
}

output "db_write_replay_queue_arn" {
  description = "ARN of the FIFO database write replay queue"
  value       = aws_sqs_queue.db_write_replay.arn
}

output "db_write_replay_dlq_url" {
  description = "URL of the FIFO database write replay dead-letter queue"
  value       = aws_sqs_queue.db_write_replay_dlq.url
}

output "db_write_replay_dlq_arn" {
  description = "ARN of the FIFO database write replay dead-letter queue"
  value       = aws_sqs_queue.db_write_replay_dlq.arn
}

output "backend_db_write_replay_producer_policy_arn" {
  description = "ARN of the managed policy allowing the Backend to enqueue rejected database writes"
  value       = aws_iam_policy.backend_db_write_replay_producer.arn
}

output "db_write_replay_consumer_policy_arn" {
  description = "ARN of the managed policy attached to the database write replay Lambda"
  value       = aws_iam_policy.db_write_replay_consumer.arn
}

output "db_write_replay_forwarder_lambda_name" {
  description = "Name of the Lambda that forwards FIFO replay messages to the Backend replay endpoint"
  value       = aws_lambda_function.db_write_replay_forwarder.function_name
}

output "db_write_replay_event_source_mapping_uuid" {
  description = "UUID of the disabled-by-default SQS event source mapping for the replay Lambda"
  value       = aws_lambda_event_source_mapping.db_write_replay_forwarder.uuid
}

output "db_write_replay_token_secret_name" {
  description = "Secrets Manager secret name whose value is shared with the Backend replay endpoint"
  value       = aws_secretsmanager_secret.db_write_replay_token.name
}

output "backend_producer_sqs_policy_arn" {
  description = "ARN of the managed IAM policy for Backend report and order publishing"
  value       = aws_iam_policy.backend_producer_sqs.arn
}

output "order_consumer_sqs_policy_arn" {
  description = "ARN of the managed IAM policy for order consumption"
  value       = aws_iam_policy.order_consumer_sqs.arn
}

output "ai_sqs_policy_arn" {
  description = "ARN of the managed IAM policy for the AI service SQS access"
  value       = aws_iam_policy.ai_sqs.arn
}

output "sqs_dashboard_name" {
  description = "Name of the CloudWatch dashboard for the SQS queues"
  value       = aws_cloudwatch_dashboard.sqs.dashboard_name
}

output "report_dlq_alarm_name" {
  description = "Name of the CloudWatch alarm for visible messages in the report DLQ"
  value       = aws_cloudwatch_metric_alarm.report_dlq_not_empty.alarm_name
}

output "order_dlq_alarm_name" {
  description = "Name of the CloudWatch alarm for visible messages in the order DLQ"
  value       = aws_cloudwatch_metric_alarm.order_dlq_not_empty.alarm_name
}

output "db_write_replay_dlq_alarm_name" {
  description = "Name of the CloudWatch alarm for visible messages in the database write replay DLQ"
  value       = aws_cloudwatch_metric_alarm.db_write_replay_dlq_not_empty.alarm_name
}

output "sqs_discord_webhook_secret_name" {
  description = "Secrets Manager secret where the SQS Discord webhook URL must be stored outside Terraform"
  value       = aws_secretsmanager_secret.sqs_discord_webhook.name
}

output "sqs_discord_notifier_lambda_name" {
  description = "Name of the Lambda that sends SQS alarm notifications to Discord"
  value       = aws_lambda_function.sqs_discord_notifier.function_name
}
