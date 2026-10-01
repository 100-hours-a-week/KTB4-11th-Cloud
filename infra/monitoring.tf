data "aws_caller_identity" "monitoring" {}

data "aws_partition" "monitoring" {}

locals {
  app_cloudwatch_namespace           = "CWAgent"
  app_system_log_group_name          = "/stockspoon/app/system"
  app_system_log_group_arn           = "arn:${data.aws_partition.monitoring.partition}:logs:${var.aws_region}:${data.aws_caller_identity.monitoring.account_id}:log-group:${local.app_system_log_group_name}"
  app_system_log_stream_arn_glob     = "${local.app_system_log_group_arn}:log-stream:*"
  app_container_log_group_name       = "/stockspoon/app/containers"
  app_container_log_group_arn_prefix = "arn:${data.aws_partition.monitoring.partition}:logs:${var.aws_region}:${data.aws_caller_identity.monitoring.account_id}:log-group:"
  app_container_log_group_arn        = "${local.app_container_log_group_arn_prefix}${local.app_container_log_group_name}"
  app_container_log_stream_arn_glob  = "${local.app_container_log_group_arn}:log-stream:*"
  app_container_service_log_group_names = {
    nginx    = "${local.app_container_log_group_name}/nginx"
    frontend = "${local.app_container_log_group_name}/frontend"
    backend  = "${local.app_container_log_group_name}/backend"
    db       = "${local.app_container_log_group_name}/db"
  }
  app_container_service_log_stream_arn_globs = [
    for log_group_name in values(local.app_container_service_log_group_names) :
    "${local.app_container_log_group_arn_prefix}${log_group_name}:log-stream:*"
  ]
}

resource "aws_cloudwatch_log_group" "app_system" {
  name              = local.app_system_log_group_name
  retention_in_days = 14

  tags = {
    Name        = "stockspoon-v1-app-system-logs"
    Project     = "stockspoon"
    Environment = "v1"
    ManagedBy   = "Terraform"
  }
}

# Keep the old aggregate group during migration so its existing events remain
# available while Compose containers move to the per-service groups below.
resource "aws_cloudwatch_log_group" "app_containers" {
  name              = local.app_container_log_group_name
  retention_in_days = 7

  tags = {
    Name        = "stockspoon-v1-app-container-logs"
    Project     = "stockspoon"
    Environment = "v1"
    ManagedBy   = "Terraform"
  }
}

resource "aws_cloudwatch_log_group" "app_container_services" {
  for_each = local.app_container_service_log_group_names

  name              = each.value
  retention_in_days = 7

  tags = {
    Name        = "stockspoon-v1-app-${each.key}-logs"
    Project     = "stockspoon"
    Environment = "v1"
    ManagedBy   = "Terraform"
  }
}

resource "aws_cloudwatch_log_metric_filter" "app_storage_errors" {
  name           = "stockspoon-v1-app-storage-errors"
  log_group_name = aws_cloudwatch_log_group.app_system.name
  pattern        = "?\"I/O error\" ?blk_update_request ?\"EXT4-fs error\" ?\"Buffer I/O error\" ?\"I/O timeout\" ?\"critical medium error\""

  metric_transformation {
    name      = "StorageDeviceErrorCount"
    namespace = "Stockspoon/USE"
    value     = "1"
    unit      = "Count"
  }
}

data "aws_iam_policy_document" "app_cloudwatch_agent_assume_role" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "app_cloudwatch_agent" {
  name               = "stockspoon-v1-app-cloudwatch-agent-role"
  assume_role_policy = data.aws_iam_policy_document.app_cloudwatch_agent_assume_role.json

  tags = {
    Name        = "stockspoon-v1-app-cloudwatch-agent-role"
    Project     = "stockspoon"
    Environment = "v1"
    ManagedBy   = "Terraform"
  }
}

data "aws_iam_policy_document" "app_cloudwatch_agent" {
  statement {
    sid       = "PublishCWAgentMetrics"
    effect    = "Allow"
    actions   = ["cloudwatch:PutMetricData"]
    resources = ["*"]

    condition {
      test     = "StringEquals"
      variable = "cloudwatch:namespace"
      values   = [local.app_cloudwatch_namespace]
    }
  }

  statement {
    sid       = "DescribeLogGroups"
    effect    = "Allow"
    actions   = ["logs:DescribeLogGroups"]
    resources = ["*"]
  }

  statement {
    sid       = "DescribeAppSystemLogStreams"
    effect    = "Allow"
    actions   = ["logs:DescribeLogStreams"]
    resources = [local.app_system_log_group_arn]
  }

  statement {
    sid    = "PublishAppContainerLogs"
    effect = "Allow"
    actions = [
      "logs:CreateLogStream",
      "logs:PutLogEvents",
    ]
    resources = concat(
      [local.app_container_log_stream_arn_glob],
      local.app_container_service_log_stream_arn_globs
    )
  }

  statement {
    sid    = "PublishAppSystemLogs"
    effect = "Allow"
    actions = [
      "logs:CreateLogStream",
      "logs:PutLogEvents",
    ]
    resources = [local.app_system_log_stream_arn_glob]
  }
}

resource "aws_iam_role_policy" "app_cloudwatch_agent" {
  name   = "stockspoon-v1-app-cloudwatch-agent-policy"
  role   = aws_iam_role.app_cloudwatch_agent.id
  policy = data.aws_iam_policy_document.app_cloudwatch_agent.json
}

resource "aws_iam_instance_profile" "app_cloudwatch_agent" {
  name = "stockspoon-v1-app-cloudwatch-agent-profile"
  role = aws_iam_role.app_cloudwatch_agent.name

  tags = {
    Name        = "stockspoon-v1-app-cloudwatch-agent-profile"
    Project     = "stockspoon"
    Environment = "v1"
    ManagedBy   = "Terraform"
  }
}
