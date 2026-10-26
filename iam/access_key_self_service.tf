locals {
  access_key_self_service_users = toset([
    "eric",
    "ezra",
    "lily",
    "river",
  ])
}

resource "aws_iam_user_policy" "create_own_access_keys" {
  for_each = local.access_key_self_service_users

  name = "stockspoon-create-own-access-keys"
  user = aws_iam_user.existing[each.value].name

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "CreateOwnAccessKeys"
        Effect = "Allow"
        Action = [
          "iam:CreateAccessKey",
          "iam:GetUser",
          "iam:ListAccessKeys",
        ]
        Resource = aws_iam_user.existing[each.value].arn
      },
    ]
  })
}
