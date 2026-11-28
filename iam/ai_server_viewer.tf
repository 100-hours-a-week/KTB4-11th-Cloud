data "aws_iam_policy_document" "ai_server_viewer" {
  statement {
    sid    = "DescribeEc2InstancesInSeoul"
    effect = "Allow"

    actions = [
      "ec2:DescribeInstances",
      "ec2:DescribeInstanceStatus",
    ]

    resources = ["*"]

    # EC2 Describe APIs cannot be scoped to one instance, so this is limited to Seoul.
    condition {
      test     = "StringEquals"
      variable = "ec2:Region"
      values   = ["ap-northeast-2"]
    }
  }
}

resource "aws_iam_group_policy" "ai_server_viewer" {
  name   = "stockspoon-ai-server-viewer"
  group  = aws_iam_group.ai_server_viewer.name
  policy = data.aws_iam_policy_document.ai_server_viewer.json
}
