mock_provider "aws" {
  mock_data "aws_caller_identity" {
    defaults = { account_id = "123456789012" }
  }
  mock_data "aws_partition" {
    defaults = { partition = "aws" }
  }
  mock_resource "aws_iam_role" {
    defaults = { arn = "arn:aws:iam::123456789012:role/test-ai-notifier" }
  }
  mock_resource "aws_lambda_function" {
    defaults = { arn = "arn:aws:lambda:ap-northeast-2:123456789012:function:test-ai-notifier" }
  }

  mock_data "aws_iam_policy_document" {
    defaults = { json = "{}" }
  }
}

run "explicit_cloudwatch_owner_retains_existing_alarms" {
  command = plan
  variables {
    ai_host_alert_owner = "cloudwatch"
  }

  assert {
    condition = (
      length(aws_cloudwatch_metric_alarm.ai_cpu_high) == 1 &&
      length(aws_cloudwatch_metric_alarm.ai_metrics_missing) == 1 &&
      length(aws_cloudwatch_metric_alarm.ai_memory_high) == 1 &&
      length(aws_cloudwatch_metric_alarm.ai_root_disk_high) == 1
    )
    error_message = "Host alarms must remain until the Grafana migration is explicitly verified."
  }
}

run "verified_default_removes_only_host_alarms" {
  command = plan

  assert {
    condition = (
      length(aws_cloudwatch_metric_alarm.ai_cpu_high) == 0 &&
      length(aws_cloudwatch_metric_alarm.ai_metrics_missing) == 0 &&
      length(aws_cloudwatch_metric_alarm.ai_memory_high) == 0 &&
      length(aws_cloudwatch_metric_alarm.ai_root_disk_high) == 0
    )
    error_message = "Verified Grafana migration must retire exactly the four host alarms."
  }

  assert {
    condition = (
      aws_cloudwatch_metric_alarm.ai_container_failure.metric_name == "ContainerFailureCount" &&
      aws_cloudwatch_metric_alarm.ai_ec2_status_check_failed.metric_name == "StatusCheckFailed" &&
      aws_cloudwatch_metric_alarm.ai_storage_device_error.metric_name == "StorageDeviceErrorCount" &&
      aws_cloudwatch_metric_alarm.ai_application_log_errors.metric_name == "ErrorCount" &&
      length(aws_cloudwatch_metric_alarm.ai_scheduled_job_failure) == 5
    )
    error_message = "DB container, EC2 status, storage, log and scheduled-job monitoring must be preserved."
  }
}

run "unverified_owner_is_rejected" {
  command = plan
  variables {
    ai_host_alert_owner = "grafana"
  }
  expect_failures = [var.ai_host_alert_owner]
}
