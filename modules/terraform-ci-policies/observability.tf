data "aws_iam_policy_document" "terraform_ci_write_observability" {
  statement {
    sid    = "ManageRepositoryObservabilityInSeoul"
    effect = "Allow"
    actions = [
      "cloudwatch:DeleteAlarms",
      "cloudwatch:DeleteDashboards",
      "cloudwatch:PutDashboard",
      "cloudwatch:PutMetricAlarm",
      "cloudwatch:TagResource",
      "cloudwatch:UntagResource",
      "logs:CreateLogGroup",
      "logs:DeleteLogGroup",
      "logs:DeleteMetricFilter",
      "logs:DeleteRetentionPolicy",
      "logs:PutMetricFilter",
      "logs:PutRetentionPolicy",
      "logs:PutResourcePolicy",
      "logs:DeleteResourcePolicy",
      "logs:TagResource",
      "logs:UntagResource",
      "events:PutRule",
      "events:DeleteRule",
      "events:PutTargets",
      "events:RemoveTargets",
      "events:TagResource",
      "events:UntagResource",
    ]
    resources = ["*"]

    condition {
      test     = "StringEquals"
      variable = "aws:RequestedRegion"
      values   = ["ap-northeast-2"]
    }
  }
}
