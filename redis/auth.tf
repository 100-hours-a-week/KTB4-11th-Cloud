resource "aws_elasticache_user" "backend" {
  user_id       = local.backend_user_id
  user_name     = local.backend_user_id
  access_string = local.backend_access_string
  engine        = "valkey"

  authentication_mode {
    type = "iam"
  }

  tags = {
    Name = local.backend_user_id
  }
}

resource "aws_elasticache_user_group" "applications" {
  user_group_id = local.user_group_id
  engine        = "valkey"
  user_ids      = [aws_elasticache_user.backend.user_id]

  tags = {
    Name = local.user_group_id
  }
}
