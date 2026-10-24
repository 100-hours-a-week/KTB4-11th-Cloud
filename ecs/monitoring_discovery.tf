resource "aws_iam_role" "telemetry_alloy" {
  count              = var.plg_tempo_enabled ? 1 : 0
  name               = "${local.telemetry_name}-discovery-task-role"
  assume_role_policy = data.aws_iam_policy_document.ecs_tasks_assume_role.json
}

data "aws_iam_policy_document" "telemetry_alloy_discovery" {
  statement {
    actions   = ["ecs:ListClusters", "ec2:DescribeInstances", "ec2:DescribeNetworkInterfaces"]
    resources = ["*"]
    condition {
      test     = "StringEquals"
      variable = "aws:RequestedRegion"
      values   = [var.aws_region]
    }
  }
  statement {
    actions = ["ecs:DescribeClusters"]
    resources = [
      aws_ecs_cluster.main.arn,
      "arn:${local.partition}:ecs:${var.aws_region}:${local.account_id}:cluster/default",
    ]
  }
  statement {
    actions   = ["ecs:ListServices", "ecs:ListTasks"]
    resources = ["*"]
    condition {
      test     = "ArnEquals"
      variable = "ecs:cluster"
      values   = [aws_ecs_cluster.main.arn]
    }
  }
  statement {
    actions = ["ecs:DescribeServices", "ecs:DescribeTasks", "ecs:DescribeContainerInstances"]
    resources = [
      "arn:${local.partition}:ecs:${var.aws_region}:${local.account_id}:service/${aws_ecs_cluster.main.name}/*",
      "arn:${local.partition}:ecs:${var.aws_region}:${local.account_id}:task/${aws_ecs_cluster.main.name}/*",
      "arn:${local.partition}:ecs:${var.aws_region}:${local.account_id}:container-instance/${aws_ecs_cluster.main.name}/*",
    ]
  }
}

resource "aws_iam_role_policy" "telemetry_alloy_discovery" {
  count  = var.plg_tempo_enabled ? 1 : 0
  name   = "${local.telemetry_name}-discovery-read"
  role   = aws_iam_role.telemetry_alloy[0].id
  policy = data.aws_iam_policy_document.telemetry_alloy_discovery.json
}
