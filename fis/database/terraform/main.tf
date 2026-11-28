terraform {
  required_version = ">= 1.11.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
  }
}

variable "deployment_profile" {
  type        = string
  description = "Explicit local AWS profile used to manage the production FIS template."

  validation {
    condition     = trimspace(var.deployment_profile) != ""
    error_message = "Select an explicit AWS profile for the production account."
  }
}

variable "target_database_instance_id" {
  type        = string
  description = "The EC2 instance currently confirmed as the writable MySQL primary. Must be one of the two DB instances in app-server state."

  validation {
    condition     = can(regex("^i-[0-9a-f]+$", var.target_database_instance_id))
    error_message = "Provide a valid EC2 instance ID for one of the Database Infra nodes."
  }
}

variable "primary_restart_after_minutes" {
  type        = number
  description = "How long FIS keeps the selected DB host stopped before EC2 restarts it. This injection duration is not an RTO objective."
  default     = 10

  validation {
    condition     = var.primary_restart_after_minutes >= 1 && var.primary_restart_after_minutes <= 720 && floor(var.primary_restart_after_minutes) == var.primary_restart_after_minutes
    error_message = "Set a whole-number restart interval from 1 to 720 minutes."
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
      Scope       = "database-fis"
      ManagedBy   = "Terraform"
      Issue       = "352"
    }
  }
}

data "aws_caller_identity" "current" {}
data "aws_partition" "current" {}

data "terraform_remote_state" "app" {
  backend = "s3"

  config = {
    bucket = "stockspoon-terraform-state-v1"
    key    = "app-server/terraform.tfstate"
    region = "ap-northeast-2"
  }
}

data "terraform_remote_state" "ecs" {
  backend = "s3"

  config = {
    bucket = "stockspoon-terraform-state-v2"
    key    = "ecs/terraform.tfstate"
    region = "ap-northeast-2"
  }
}

locals {
  database_instance_ids = toset([
    for instance_id in [
      try(data.terraform_remote_state.app.outputs.db_migration_host.instance_id, null),
      try(data.terraform_remote_state.app.outputs.db_private_replica_host.instance_id, null),
    ] : instance_id if instance_id != null
  ])

  database_target_arn = data.aws_instance.database_target.arn

  stop_alarm_arns = toset(compact([
    try(data.terraform_remote_state.ecs.outputs.ecs_fault_stop_alarm_arns["backend-availability"], ""),
    try(data.terraform_remote_state.ecs.outputs.ecs_fault_stop_alarm_arns["backend-errors"], ""),
  ]))
}

data "aws_instance" "database_target" {
  instance_id = var.target_database_instance_id
}

data "aws_ebs_volumes" "database_target" {
  filter {
    name   = "attachment.instance-id"
    values = [var.target_database_instance_id]
  }
}

data "aws_ebs_volume" "database_target" {
  for_each = toset(data.aws_ebs_volumes.database_target.ids)

  filter {
    name   = "volume-id"
    values = [each.value]
  }
}

locals {
  database_target_kms_key_arns = toset([
    for volume in data.aws_ebs_volume.database_target : volume.kms_key_id
    if volume.encrypted && volume.kms_key_id != null && volume.kms_key_id != ""
  ])
}

resource "aws_iam_role" "fis" {
  name = "stockspoon-db-primary-fis"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "fis.amazonaws.com" }
      Action    = "sts:AssumeRole"
      Condition = {
        StringEquals = { "aws:SourceAccount" = data.aws_caller_identity.current.account_id }
        ArnLike = {
          "aws:SourceArn" = "arn:${data.aws_partition.current.partition}:fis:ap-northeast-2:${data.aws_caller_identity.current.account_id}:experiment/*"
        }
      }
    }]
  })
}

resource "aws_iam_role_policy" "fis" {
  name = "stockspoon-db-primary-fis"
  role = aws_iam_role.fis.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid      = "StopAndRestartOnlySelectedDatabaseNode"
        Effect   = "Allow"
        Action   = ["ec2:StopInstances", "ec2:StartInstances"]
        Resource = [local.database_target_arn]
      },
      {
        Sid    = "ResolveSelectedInstanceAndStopAlarms"
        Effect = "Allow"
        Action = [
          "ec2:DescribeInstances",
          "ec2:DescribeVolumes",
          "cloudwatch:DescribeAlarms",
        ]
        Resource = "*"
      },
      {
        # FIS configures vended log delivery using the experiment role.
        Sid    = "ConfigureExperimentLogDelivery"
        Effect = "Allow"
        Action = [
          "logs:CreateLogDelivery",
          "logs:PutResourcePolicy",
          "logs:DescribeResourcePolicies",
          "logs:DescribeLogGroups",
        ]
        Resource = "*"
      },
    ]
  })
}

resource "aws_iam_role_policy" "fis_kms" {
  count = length(local.database_target_kms_key_arns) == 0 ? 0 : 1

  name = "stockspoon-db-primary-fis-kms"
  role = aws_iam_role.fis.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid      = "GrantEC2AccessToSelectedEncryptedVolumes"
      Effect   = "Allow"
      Action   = ["kms:CreateGrant"]
      Resource = local.database_target_kms_key_arns
      Condition = {
        Bool = { "kms:GrantIsForAWSResource" = "true" }
      }
    }]
  })
}

resource "aws_cloudwatch_log_group" "fis" {
  name              = "/aws/vendedlogs/fis/stockspoon-db-primary-fis"
  retention_in_days = 30
}

# This resource creates a manual-start template only. Terraform never starts a FIS experiment.
resource "aws_fis_experiment_template" "db_primary_stop" {
  description = "Database Infra: abruptly stop the explicitly selected writable MySQL EC2 node; restart after the configured interval; manual experiment start only"
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
    for_each = local.stop_alarm_arns

    content {
      source = "aws:cloudwatch:alarm"
      value  = stop_condition.value
    }
  }

  target {
    name           = "SelectedDatabasePrimary"
    resource_type  = "aws:ec2:instance"
    resource_arns  = [local.database_target_arn]
    selection_mode = "COUNT(1)"
  }

  action {
    name      = "AbruptlyStopSelectedDatabasePrimary"
    action_id = "aws:ec2:stop-instances"

    target {
      key   = "Instances"
      value = "SelectedDatabasePrimary"
    }

    parameter {
      key   = "skipOsShutdown"
      value = "true"
    }

    parameter {
      key   = "startInstancesAfterDuration"
      value = "PT${var.primary_restart_after_minutes}M"
    }
  }

  action {
    name        = "ObservePostFaultRecovery"
    action_id   = "aws:fis:wait"
    start_after = ["AbruptlyStopSelectedDatabasePrimary"]

    parameter {
      key   = "duration"
      value = "PT10M"
    }
  }

  lifecycle {
    precondition {
      condition     = contains(local.database_instance_ids, data.aws_instance.database_target.id)
      error_message = "The selected EC2 instance must be one of the MySQL nodes exported by app-server state."
    }

    precondition {
      condition     = data.aws_instance.database_target.instance_state == "running"
      error_message = "The selected Database Infra EC2 instance must be running before this template is provisioned."
    }

    precondition {
      condition     = length(local.stop_alarm_arns) == 2
      error_message = "The ECS state must export both backend FIS stop alarms (availability and target 5xx)."
    }
  }

  tags = {
    Name  = "stockspoon-db-primary-fis"
    Issue = "352"
  }

  depends_on = [aws_iam_role_policy.fis, aws_iam_role_policy.fis_kms]
}

output "template_id" {
  value = aws_fis_experiment_template.db_primary_stop.id
}

output "target_database_instance_arn" {
  value = local.database_target_arn
}

output "primary_restart_after_minutes" {
  value = var.primary_restart_after_minutes
}

output "experiment_log_group_name" {
  value = aws_cloudwatch_log_group.fis.name
}

output "stop_alarm_arns" {
  value = local.stop_alarm_arns
}
