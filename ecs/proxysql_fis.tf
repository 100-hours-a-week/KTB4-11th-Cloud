# AWS FIS registers the task's SSM agent sidecar as a managed instance. Keep
# these permissions on a Fargate-only task role so the legacy EC2 task role is
# not given fault-injection registration permissions.
resource "aws_iam_role" "proxysql_fargate_task" {
  name               = "${var.name_prefix}-proxysql-fargate-task-role"
  description        = "Fargate ProxySQL task role for AWS FIS SSM registration"
  assume_role_policy = data.aws_iam_policy_document.ecs_tasks_assume_role.json
}

resource "aws_iam_role_policy" "proxysql_fargate_task_fis_registration" {
  name = "${var.name_prefix}-proxysql-fis-registration"
  role = aws_iam_role.proxysql_fargate_task.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = ["ssm:CreateActivation", "ssm:AddTagsToResource"]
        Resource = "*"
        Condition = {
          StringEquals = { "aws:RequestTag/FAULT_INJECTION_SIDECAR" = "true" }
          StringLike   = { "aws:RequestTag/ECS_TASK_ARN" = "arn:${local.partition}:ecs:${var.aws_region}:${local.account_id}:task/${aws_ecs_cluster.main.name}/*" }
        }
      },
      {
        Effect   = "Allow"
        Action   = "iam:PassRole"
        Resource = aws_iam_role.proxysql_fis_managed.arn
        Condition = {
          StringEquals = { "iam:PassedToService" = "ssm.amazonaws.com" }
        }
      },
    ]
  })
}

resource "aws_iam_role" "proxysql_fis_managed" {
  name = "${var.name_prefix}-proxysql-fis-ssm"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "ssm.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy_attachment" "proxysql_fis_managed_core" {
  role       = aws_iam_role.proxysql_fis_managed.name
  policy_arn = "arn:${local.partition}:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_role_policy" "proxysql_fis_managed_cleanup" {
  name = "${var.name_prefix}-proxysql-fis-cleanup"
  role = aws_iam_role.proxysql_fis_managed.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      { Effect = "Allow", Action = "ssm:DeleteActivation", Resource = "*" },
      {
        Effect   = "Allow"
        Action   = "ssm:DeregisterManagedInstance"
        Resource = "arn:${local.partition}:ssm:${var.aws_region}:${local.account_id}:managed-instance/*"
        Condition = {
          StringEquals = { "ssm:resourceTag/FAULT_INJECTION_SIDECAR" = "true" }
        }
      },
    ]
  })
}

output "proxysql_fis_managed_role_name" {
  description = "SSM managed-instance role used by the ProxySQL Fargate FIS sidecar"
  value       = aws_iam_role.proxysql_fis_managed.name
}
