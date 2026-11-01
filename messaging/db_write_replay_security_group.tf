# Temporarily retain the production replay security group until the ECS root
# removes its cross-root ProxySQL ingress rule. A follow-up change deletes it.
moved {
  from = aws_security_group.db_write_replay_forwarder
  to   = aws_security_group.db_write_replay_forwarder[0]
}

resource "aws_security_group" "db_write_replay_forwarder" {
  count       = var.environment == "prod" ? 1 : 0
  name        = "${local.name_prefix}-db-write-replay-forwarder-sg"
  description = "Allows the manually invoked DB write replay Lambda to reach ProxySQL"
  vpc_id      = data.terraform_remote_state.shared.outputs.vpc_id

  tags = {
    Name = "${local.name_prefix}-db-write-replay-forwarder-sg"
  }
}
