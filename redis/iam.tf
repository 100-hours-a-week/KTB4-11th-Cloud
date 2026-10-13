# 사용자마다 Connect Policy를 분리해, 연결된 Role이 자기 사용자로만 접속하게 합니다.
data "aws_iam_policy_document" "app_connect" {
  for_each = local.app_users

  statement {
    sid     = local.is_dev ? "ConnectToDevelopmentValkey" : "ConnectToProductionValkey"
    effect  = "Allow"
    actions = ["elasticache:Connect"]
    resources = [
      aws_elasticache_serverless_cache.valkey.arn,
      aws_elasticache_user.app[each.key].arn,
    ]
  }
}

resource "aws_iam_policy" "app_connect" {
  for_each = local.app_users

  name = "${each.value.user_id}-connect"
  # IAM Policy 설명은 변경 시 교체되므로 dev 값은 기존 문구를 유지합니다.
  description = local.is_dev ? "Allow the future V2 development Backend to connect to Valkey" : "Allow the V2 production ${each.key} service to connect to Valkey as its own user"
  policy      = data.aws_iam_policy_document.app_connect[each.key].json

  tags = {
    Name = "${each.value.user_id}-connect"
  }
}

# 개발 Backend·AI EC2 Role 연결 (dev 전용, prod에서는 ecs root가 Task Role에 연결)
resource "aws_iam_role_policy_attachment" "backend_connect" {
  count      = local.backend_iam_role_name == null ? 0 : 1
  role       = local.backend_iam_role_name
  policy_arn = aws_iam_policy.app_connect["backend"].arn
}

resource "aws_iam_role_policy_attachment" "ai_connect" {
  count      = local.ai_iam_role_name == null ? 0 : 1
  role       = local.ai_iam_role_name
  policy_arn = aws_iam_policy.app_connect["backend"].arn
}
