data "aws_iam_policy_document" "backend_connect" {
  statement {
    sid     = "ConnectToDevelopmentValkey"
    effect  = "Allow"
    actions = ["elasticache:Connect"]
    resources = [
      aws_elasticache_serverless_cache.valkey.arn,
      aws_elasticache_user.backend.arn,
    ]
  }
}

resource "aws_iam_policy" "backend_connect" {
  name        = "${local.name_prefix}-backend-connect"
  description = "Allow the future V2 development Backend to connect to Valkey"
  policy      = data.aws_iam_policy_document.backend_connect.json

  tags = {
    Name = "${local.name_prefix}-backend-connect"
  }
}
