resource "aws_elasticache_user" "app" {
  for_each = local.app_users

  user_id       = each.value.user_id
  user_name     = each.value.user_id
  access_string = each.value.access_string
  engine        = "valkey"

  authentication_mode {
    type = "iam"
  }

  tags = {
    Name = each.value.user_id
  }
}

resource "aws_elasticache_user_group" "applications" {
  user_group_id = local.user_group_id
  engine        = "valkey"
  user_ids      = [for user in aws_elasticache_user.app : user.user_id]

  tags = {
    Name = local.user_group_id
  }
}
