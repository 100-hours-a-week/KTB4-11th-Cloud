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

output "backend_sqs_policy_arn" {
  description = "ARN of the managed IAM policy for the Backend SQS access"
  value       = aws_iam_policy.backend_sqs.arn
}

output "ai_sqs_policy_arn" {
  description = "ARN of the managed IAM policy for the AI service SQS access"
  value       = aws_iam_policy.ai_sqs.arn
}
