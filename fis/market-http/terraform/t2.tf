# Template only; it does not change service capacity or start an experiment.
resource "aws_fis_experiment_template" "stop_peak" {
  description = "T2 market-http: 3 Tasks and 2000 SSE; stop exactly one verified Task; manual start only"
  role_arn    = aws_iam_role.fis.arn

  log_configuration {
    log_schema_version = 2
    cloudwatch_logs_configuration {
      log_group_arn = "${aws_cloudwatch_log_group.fis.arn}:*"
    }
  }

  experiment_options {
    account_targeting            = "single-account"
    empty_target_resolution_mode = "fail"
  }

  dynamic "stop_condition" {
    for_each = var.stop_alarm_arns
    content {
      source = "aws:cloudwatch:alarm"
      value  = stop_condition.value
    }
  }

  target {
    name           = "VerifiedMarketHttpTask"
    resource_type  = "aws:ecs:task"
    resource_arns  = [var.target_task_arn]
    selection_mode = "COUNT(1)"
    # AWS rejects resource_arns combined with filters. preflight.py verifies
    # RUNNING status and service membership; IAM permits only this exact ARN.
  }

  action {
    name      = "StopOneMarketHttpTask"
    action_id = "aws:ecs:stop-task"
    target {
      key   = "Tasks"
      value = "VerifiedMarketHttpTask"
    }
  }

  action {
    name        = "ObserveRecovery"
    action_id   = "aws:fis:wait"
    start_after = ["StopOneMarketHttpTask"]
    parameter {
      key   = "duration"
      value = "PT10M"
    }
  }

  tags       = { Name = "stockspoon-market-http-t2-stop-one", Scenario = "T2" }
  depends_on = [aws_iam_role_policy.fis]
}

output "t2_template_id" {
  value = aws_fis_experiment_template.stop_peak.id
}
