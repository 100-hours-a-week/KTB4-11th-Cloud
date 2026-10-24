# Monitoring creates these slots once; operators maintain the webhook values.
# Scope bootstrap access to the two development service parameters.
data "aws_iam_policy_document" "github_actions_terraform_monitoring_webhooks" {
  statement {
    sid     = "BootstrapDevelopmentMonitoringWebhooks"
    effect  = "Allow"
    actions = ["ssm:PutParameter", "ssm:AddTagsToResource"]
    resources = [
      for service in ["fe", "be"] :
      "arn:${data.aws_partition.github_actions_terraform.partition}:ssm:ap-northeast-2:${data.aws_caller_identity.github_actions_terraform.account_id}:parameter/stockspoon/monitoring/dev/${service}/discord-webhook"
    ]
  }
}

resource "aws_iam_role_policy" "github_actions_terraform_monitoring_webhooks" {
  name   = "stockspoon-v1-github-actions-terraform-monitoring-webhooks"
  role   = aws_iam_role.github_actions_terraform_apply.id
  policy = data.aws_iam_policy_document.github_actions_terraform_monitoring_webhooks.json
}

# Adopt the policy installed by the administrator without requiring the apply
# role to create or modify a policy attached to itself.
import {
  to = aws_iam_role_policy.github_actions_terraform_monitoring_webhooks
  id = "stockspoon-v1-github-actions-terraform-apply:stockspoon-v1-github-actions-terraform-monitoring-webhooks"
}
