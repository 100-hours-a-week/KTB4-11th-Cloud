mock_provider "aws" {}

variables {
  deployment_profile = "offline-test-only"
  target_task_arn    = "arn:aws:ecs:ap-northeast-2:250832562715:task/stockspoon-v2-prod-cluster/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
  stop_alarm_arns    = ["arn:aws:cloudwatch:ap-northeast-2:250832562715:alarm:offline-test-only"]
}

run "one_task_only" {
  command = plan
  assert {
    condition = length(aws_fis_experiment_template.stop_one.target) == 1 && alltrue([
      for target in aws_fis_experiment_template.stop_one.target :
      target.selection_mode == "COUNT(1)" && target.resource_arns == toset([var.target_task_arn]) && length(target.filter) == 0
    ])
    error_message = "The template must resolve exactly one explicitly supplied Task."
  }
  assert {
    condition = toset([for action in aws_fis_experiment_template.stop_one.action : action.action_id]) == toset([
      "aws:ecs:stop-task", "aws:fis:wait"
    ])
    error_message = "Only StopTask and the recovery observation wait are permitted."
  }
  assert {
    condition     = jsondecode(aws_iam_role_policy.fis.policy).Statement[0].Resource == var.target_task_arn
    error_message = "IAM must restrict the write action to the exact Task ARN."
  }
  assert {
    condition = alltrue([
      for config in aws_fis_experiment_template.stop_one.log_configuration :
      config.log_schema_version == 2 && length(config.cloudwatch_logs_configuration) == 1
    ]) && length(aws_fis_experiment_template.stop_one.log_configuration) == 1
    error_message = "FIS must deliver schema v2 experiment logs to CloudWatch Logs."
  }
}

run "explicit_profile_required" {
  command = plan
  variables {
    deployment_profile = ""
  }
  expect_failures = [var.deployment_profile]
}

run "wrong_cluster_rejected" {
  command = plan
  variables {
    target_task_arn = "arn:aws:ecs:ap-northeast-2:250832562715:task/backend-cluster/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
  }
  expect_failures = [var.target_task_arn]
}

run "missing_stop_alarm_rejected" {
  command = plan
  variables {
    stop_alarm_arns = []
  }
  expect_failures = [var.stop_alarm_arns]
}
