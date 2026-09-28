# The CloudWatch Agent runs on the EC2 host and uses this instance profile.
# No SSM permissions or deployment resources are included; the agent is
# installed and started manually over SSH.
resource "aws_iam_role" "app_cloudwatch_agent" {
  name = "stockspoon-v1-cloudwatch-agent"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Principal = {
        Service = "ec2.amazonaws.com"
      }
      Action = "sts:AssumeRole"
    }]
  })

  tags = {
    Name        = "stockspoon-v1-cloudwatch-agent"
    Project     = "stockspoon"
    Environment = "v1"
    ManagedBy   = "Terraform"
  }
}

resource "aws_iam_instance_profile" "app" {
  name = "stockspoon-v1-app-instance-profile"
  role = aws_iam_role.app_cloudwatch_agent.name

  tags = {
    Name        = "stockspoon-v1-app-instance-profile"
    Project     = "stockspoon"
    Environment = "v1"
    ManagedBy   = "Terraform"
  }
}

resource "aws_cloudwatch_log_group" "host_system" {
  name              = "/stockspoon/v1/host/system"
  retention_in_days = 30

  tags = {
    Name        = "stockspoon-v1-host-system"
    Project     = "stockspoon"
    Environment = "v1"
    ManagedBy   = "Terraform"
  }
}

resource "aws_cloudwatch_log_group" "host_auth" {
  name              = "/stockspoon/v1/host/auth"
  retention_in_days = 30

  tags = {
    Name        = "stockspoon-v1-host-auth"
    Project     = "stockspoon"
    Environment = "v1"
    ManagedBy   = "Terraform"
  }
}

# Scope agent permissions to the CWAgent metric namespace and the two log
# groups created above. Terraform owns log group creation and retention.
resource "aws_iam_role_policy" "app_cloudwatch_agent" {
  name = "stockspoon-v1-cloudwatch-agent-write"
  role = aws_iam_role.app_cloudwatch_agent.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid      = "PublishHostMetrics"
        Effect   = "Allow"
        Action   = ["cloudwatch:PutMetricData"]
        Resource = "*"
        Condition = {
          StringEquals = {
            "cloudwatch:namespace" = "CWAgent"
          }
        }
      },
      {
        Sid    = "WriteHostLogs"
        Effect = "Allow"
        Action = [
          "logs:CreateLogStream",
          "logs:DescribeLogStreams",
          "logs:PutLogEvents"
        ]
        Resource = [
          "${aws_cloudwatch_log_group.host_system.arn}:*",
          "${aws_cloudwatch_log_group.host_auth.arn}:*"
        ]
      },
      {
        Sid      = "DescribeLogGroups"
        Effect   = "Allow"
        Action   = ["logs:DescribeLogGroups"]
        Resource = "*"
      }
    ]
  })
}
