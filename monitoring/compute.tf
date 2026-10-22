data "aws_ssm_parameter" "telemetry_ami" {
  count = var.plg_tempo_enabled ? 1 : 0
  name  = "/aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-x86_64"
}

data "aws_subnet" "telemetry" {
  count = var.plg_tempo_enabled ? 1 : 0
  id    = data.terraform_remote_state.shared.outputs.private_subnet_ids[0]
}

resource "aws_ebs_volume" "telemetry" {
  count             = var.plg_tempo_enabled ? 1 : 0
  availability_zone = data.aws_subnet.telemetry[0].availability_zone
  type              = "gp3"
  size              = var.plg_tempo_data_size_gib
  encrypted         = true
  tags              = { Name = "${local.telemetry_name}-data" }

  lifecycle {
    prevent_destroy = true
  }
}

resource "aws_instance" "telemetry" {
  count                       = var.plg_tempo_enabled ? 1 : 0
  ami                         = data.aws_ssm_parameter.telemetry_ami[0].value
  instance_type               = var.plg_tempo_instance_type
  subnet_id                   = data.aws_subnet.telemetry[0].id
  associate_public_ip_address = false
  vpc_security_group_ids      = [aws_security_group.telemetry[0].id]
  iam_instance_profile        = aws_iam_instance_profile.telemetry[0].name
  user_data_replace_on_change = true

  # gzip keeps the bundled Compose/config files below the EC2 user-data limit.
  user_data_base64 = base64gzip(templatefile("${path.module}/bootstrap.sh.tftpl", {
    files                 = local.telemetry_files
    volume_id             = aws_ebs_volume.telemetry[0].id
    aws_region            = var.aws_region
    loki_bucket           = aws_s3_bucket.telemetry["loki"].id
    tempo_bucket          = aws_s3_bucket.telemetry["tempo"].id
    compose_name          = local.telemetry_name
    grafana_root_url      = local.grafana_root_url
    grafana_cookie_secure = local.grafana_public_enabled
  }))

  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "required"
    http_put_response_hop_limit = 2 # Loki/Tempo Docker bridge -> IMDSv2 instance role
  }

  root_block_device {
    volume_type           = "gp3"
    volume_size           = 30
    encrypted             = true
    delete_on_termination = true
  }

  tags = { Name = local.telemetry_name }
  # Latest AMI and user-data bootstrap new hosts. Neither an upstream AMI
  # release nor a config edit should replace the running monitoring server.
  # Update its config with the reviewed SSM payload from render-deploy.py.
  lifecycle {
    ignore_changes = [ami, user_data_base64]
  }
  depends_on = [
    aws_iam_role_policy.telemetry_storage,
    aws_iam_role_policy_attachment.telemetry_ssm,
    aws_vpc_security_group_egress_rule.telemetry_https,
    aws_s3_bucket_policy.telemetry_tls,
  ]
}

resource "aws_volume_attachment" "telemetry" {
  count                          = var.plg_tempo_enabled ? 1 : 0
  device_name                    = "/dev/sdf"
  volume_id                      = aws_ebs_volume.telemetry[0].id
  instance_id                    = aws_instance.telemetry[0].id
  stop_instance_before_detaching = true
}
