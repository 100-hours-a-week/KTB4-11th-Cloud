resource "aws_ssm_document" "ai_server_readonly" {
  name            = "stockspoon-ai-server-readonly"
  document_type   = "Command"
  document_format = "YAML"

  content = yamlencode({
    schemaVersion = "2.2"
    description   = "Read-only queries for the development AI server: health, disk, containers."
    parameters = {
      Query = {
        type              = "String"
        description       = "Select one approved read-only query."
        default           = "health"
        allowedValues     = ["health", "disk", "containers"]
        interpolationType = "ENV_VAR"
      }
    }
    mainSteps = [{
      action = "aws:runShellScript"
      name   = "runReadOnlyQuery"
      inputs = {
        timeoutSeconds = "30"
        runCommand = [<<-EOT
          set -eu
          case "$SSM_Query" in
            health)
              echo '--- uptime ---'
              uptime
              echo '--- memory ---'
              free -h
              ;;
            disk)
              df -h
              ;;
            containers)
              docker ps --format 'table {{.Names}}\t{{.Status}}'
              ;;
            *)
              echo 'Unsupported query.' >&2
              exit 2
              ;;
          esac
        EOT
        ]
      }
    }]
  })

  tags = {
    Name        = "stockspoon-ai-server-readonly"
    Project     = "stockspoon"
    Environment = "dev"
    ManagedBy   = "Terraform"
  }
}

data "aws_iam_policy_document" "ai_server_ssm_readonly" {
  statement {
    sid       = "SendOnlyApprovedQueryDocument"
    effect    = "Allow"
    actions   = ["ssm:SendCommand"]
    resources = [aws_ssm_document.ai_server_readonly.arn]
  }

  statement {
    sid       = "RunApprovedQueryOnlyOnDevelopmentAiServer"
    effect    = "Allow"
    actions   = ["ssm:SendCommand"]
    resources = ["arn:${data.aws_partition.current.partition}:ec2:ap-northeast-2:${data.aws_caller_identity.current.account_id}:instance/*"]

    condition {
      test     = "StringEquals"
      variable = "ssm:resourceTag/Name"
      values   = ["stockspoon-v2-dev-ai"]
    }
  }

  # GetCommandInvocation doesn't support resource-level permissions, so limit it to Seoul.
  statement {
    sid       = "ReadCommandInvocationOutputInSeoul"
    effect    = "Allow"
    actions   = ["ssm:GetCommandInvocation"]
    resources = ["*"]

    condition {
      test     = "StringEquals"
      variable = "aws:RequestedRegion"
      values   = ["ap-northeast-2"]
    }
  }
}

resource "aws_iam_group_policy" "ai_server_ssm_readonly" {
  name   = "stockspoon-ai-server-ssm-readonly"
  group  = aws_iam_group.ai_server_viewer.name
  policy = data.aws_iam_policy_document.ai_server_ssm_readonly.json
}
