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

run "redis_fault_scope" {
  command = plan
  assert {
    condition = length(aws_fis_experiment_template.redis) == 3 && alltrue([
      for template in aws_fis_experiment_template.redis : alltrue([
        for target in template.target : target.resource_arns == toset([var.target_task_arn]) && target.selection_mode == "COUNT(1)"
      ]) && length(template.stop_condition) > 0 && length(template.log_configuration) == 1
    ])
    error_message = "Each Redis scenario requires one explicit Task, stop alarms and experiment logs."
  }
  assert {
    condition = alltrue([for scenario in ["R1", "R3"] :
      local.redis_parameters[scenario].port == "6379" && local.redis_parameters[scenario].trafficType == "egress"
    ]) && local.redis_parameters.R2.sources == "stockspoon-v2-prod-valkey-kmikux.serverless.apn2.cache.amazonaws.com"
    error_message = "Blackhole must use Redis port only; latency must never default to ALL."
  }
  assert {
    condition = alltrue([for statement in jsondecode(aws_iam_role_policy.redis_fis.policy).Statement :
      !contains(statement.Action, "ecs:StopTask") && !contains(statement.Action, "ec2:TerminateInstances")
    ]) && jsondecode(aws_iam_role_policy.redis_fis.policy).Statement[2].Condition.StringEquals["ssm:resourceTag/ECS_TASK_ARN"] == var.target_task_arn
    error_message = "Redis role must not terminate resources and must scope SSM commands to the selected Task."
  }
}

run "t2_one_task_only" {
  command = plan
  assert {
    condition = length(aws_fis_experiment_template.stop_peak.target) == 1 && alltrue([
      for target in aws_fis_experiment_template.stop_peak.target :
      target.selection_mode == "COUNT(1)" && target.resource_arns == toset([var.target_task_arn]) && length(target.filter) == 0
    ])
    error_message = "T2 must stop exactly one explicitly verified Task with no target filters."
  }
  assert {
    condition = toset([for action in aws_fis_experiment_template.stop_peak.action : action.action_id]) == toset([
      "aws:ecs:stop-task", "aws:fis:wait"
    ]) && length(aws_fis_experiment_template.stop_peak.stop_condition) > 0 && length(aws_fis_experiment_template.stop_peak.log_configuration) == 1
    error_message = "T2 requires stop alarms, experiment logs and only StopTask plus observation."
  }
}

run "t3_one_task_only" {
  command = plan
  assert {
    condition = length(aws_fis_experiment_template.stop_limit.target) == 1 && alltrue([
      for target in aws_fis_experiment_template.stop_limit.target :
      target.resource_type == "aws:ecs:task" && target.selection_mode == "COUNT(1)" &&
      target.resource_arns == toset([var.target_task_arn]) && length(target.filter) == 0
    ]) && jsondecode(aws_iam_role_policy.fis.policy).Statement[0].Resource == var.target_task_arn
    error_message = "T3 must resolve exactly one verified ECS Task, with IAM restricted to that same Task."
  }
  assert {
    condition = length(aws_fis_experiment_template.stop_limit.action) == 2 && toset([
      for action in aws_fis_experiment_template.stop_limit.action : action.action_id
      ]) == toset(["aws:ecs:stop-task", "aws:fis:wait"]) && alltrue([
      for action in aws_fis_experiment_template.stop_limit.action :
      length(action.target) == 1 && alltrue([
        for target in action.target : target.key == "Tasks" && target.value == "VerifiedMarketHttpTask"
      ]) if action.action_id == "aws:ecs:stop-task"
    ])
    error_message = "T3 permits only a single targeted StopTask action and the recovery observation wait."
  }
  assert {
    condition = alltrue([
      for action in aws_fis_experiment_template.stop_limit.action :
      action.start_after == toset(["StopOneMarketHttpTask"]) && length(action.parameter) == 1 && alltrue([
        for parameter in action.parameter : parameter.key == "duration" && parameter.value == "PT10M"
      ]) if action.action_id == "aws:fis:wait"
    ])
    error_message = "T3 must observe recovery for ten minutes after StopTask."
  }
  assert {
    condition = length(aws_fis_experiment_template.stop_limit.stop_condition) == length(var.stop_alarm_arns) && alltrue([
      for condition in aws_fis_experiment_template.stop_limit.stop_condition : condition.source == "aws:cloudwatch:alarm"
      ]) && toset([
      for condition in aws_fis_experiment_template.stop_limit.stop_condition : condition.value
      ]) == var.stop_alarm_arns && length(aws_fis_experiment_template.stop_limit.log_configuration) == 1 && alltrue([
      for config in aws_fis_experiment_template.stop_limit.log_configuration :
      config.log_schema_version == 2 && length(config.cloudwatch_logs_configuration) == 1
    ]) && aws_fis_experiment_template.stop_limit.tags["Scenario"] == "T3"
    error_message = "T3 requires the supplied stop alarms, schema v2 experiment logs and its own scenario tag."
  }
}
