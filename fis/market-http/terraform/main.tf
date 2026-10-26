terraform {
  required_version = ">= 1.11.0"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
  }
}

# Deployment uses a separate operator identity. stockspoon remains read-only.
variable "deployment_profile" {
  type        = string
  description = "Explicit deployment profile; never stockspoon. No default credentials are used."
  validation {
    condition     = trimspace(var.deployment_profile) != "" && lower(trimspace(var.deployment_profile)) != "stockspoon"
    error_message = "Use a separate deployment profile. stockspoon is read-only."
  }
}

variable "target_task_arn" {
  type        = string
  description = "One live market-http Task ARN verified by preflight.py immediately before planning."
  validation {
    condition     = can(regex("^arn:aws:ecs:ap-northeast-2:250832562715:task/stockspoon-v2-prod-cluster/[a-f0-9]{32}$", var.target_task_arn))
    error_message = "Only a long Task ARN in the approved production cluster/account/region is allowed. Verify service membership using preflight.py."
  }
}

variable "stop_alarm_arns" {
  type        = set(string)
  description = "Verified CloudWatch stop alarms. No source=none option."
  validation {
    condition = length(var.stop_alarm_arns) > 0 && alltrue([
      for arn in var.stop_alarm_arns : can(regex("^arn:aws:cloudwatch:ap-northeast-2:250832562715:alarm:.+$", arn))
    ])
    error_message = "Provide at least one stop alarm in the approved account and region."
  }
}

provider "aws" {
  region              = "ap-northeast-2"
  profile             = var.deployment_profile
  allowed_account_ids = ["250832562715"]
  default_tags {
    tags = {
      Project     = "stockspoon"
      Environment = "prod"
      Scope       = "market-http-fis01"
      ManagedBy   = "Terraform"
    }
  }
}

locals {
  cluster_arn = "arn:aws:ecs:ap-northeast-2:250832562715:cluster/stockspoon-v2-prod-cluster"
}

resource "aws_iam_role" "fis" {
  name = "stockspoon-market-http-fis01"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "fis.amazonaws.com" }
      Action    = "sts:AssumeRole"
      Condition = {
        StringEquals = { "aws:SourceAccount" = "250832562715" }
        ArnLike      = { "aws:SourceArn" = "arn:aws:fis:ap-northeast-2:250832562715:experiment/*" }
      }
    }]
  })
}

resource "aws_iam_role_policy" "fis" {
  role = aws_iam_role.fis.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid      = "StopExactlyOnePreflightVerifiedTask"
        Effect   = "Allow"
        Action   = ["ecs:StopTask"]
        Resource = var.target_task_arn
        Condition = {
          ArnEquals = { "ecs:cluster" = local.cluster_arn }
        }
      },
      {
        Sid      = "DescribeSelectedTask"
        Effect   = "Allow"
        Action   = ["ecs:DescribeTasks"]
        Resource = var.target_task_arn
      },
      {
        Sid      = "ResolveTasksInApprovedCluster"
        Effect   = "Allow"
        Action   = ["ecs:ListTasks"]
        Resource = "*"
        Condition = {
          ArnEquals = { "ecs:cluster" = local.cluster_arn }
        }
      },
      {
        Sid      = "ReadTargetTagsAndStopConditions"
        Effect   = "Allow"
        Action   = ["tag:GetResources", "cloudwatch:DescribeAlarms"]
        Resource = "*"
      }
    ]
  })
}

# This resource only defines a template. It does not start an experiment.
resource "aws_fis_experiment_template" "stop_one" {
  description = "FIS-01 market-http: stop one verified Task; intraday 900 SSE; manual start only"
  role_arn    = aws_iam_role.fis.arn

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
    filter {
      path   = "lastStatus"
      values = ["RUNNING"]
    }
    filter {
      path   = "group"
      values = ["service:stockspoon-v2-prod-market-http"]
    }
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

  tags       = { Name = "stockspoon-market-http-fis01-stop-one" }
  depends_on = [aws_iam_role_policy.fis]
}

output "template_id" {
  value = aws_fis_experiment_template.stop_one.id
}

output "target_task_arn" {
  value = var.target_task_arn
}
