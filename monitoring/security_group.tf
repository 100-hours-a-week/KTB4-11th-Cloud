resource "aws_security_group" "telemetry" {
  count       = var.plg_tempo_enabled ? 1 : 0
  name        = local.telemetry_name
  description = "Private V2 PLG/Tempo; Grafana accessed through SSM"
  vpc_id      = data.terraform_remote_state.shared.outputs.vpc_id
}

resource "aws_vpc_security_group_egress_rule" "telemetry_https" {
  count             = var.plg_tempo_enabled ? 1 : 0
  security_group_id = aws_security_group.telemetry[0].id
  cidr_ipv4         = "0.0.0.0/0"
  from_port         = 443
  to_port           = 443
  ip_protocol       = "tcp"
  description       = "SSM, package/image downloads and S3 over HTTPS via NAT"
}
