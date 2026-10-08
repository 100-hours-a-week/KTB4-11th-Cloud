resource "aws_instance" "ai" {
  ami                         = var.ai_ec2_ami_id
  instance_type               = var.ai_ec2_instance_type
  key_name                    = var.ec2_key_name
  subnet_id                   = data.terraform_remote_state.test.outputs.public_subnet_id
  associate_public_ip_address = true
  iam_instance_profile        = aws_iam_instance_profile.ai_ec2.name
  vpc_security_group_ids      = [aws_security_group.ai.id]

  user_data = templatefile("${path.module}/templates/user-data.sh", {
    aws_region               = var.aws_region
    docker_compose_version   = var.docker_compose_version
    order_queue_url          = data.terraform_remote_state.messaging.outputs.order_queue_url
    report_queue_url         = data.terraform_remote_state.messaging.outputs.report_queue_url
    tailscale_auth_parameter = var.tailscale_auth_parameter_name
    tailscale_hostname       = local.name_prefix
  })

  root_block_device {
    volume_type           = "gp3"
    volume_size           = var.ai_ec2_root_volume_size_gib
    encrypted             = true
    delete_on_termination = true

    tags = {
      Name = "${local.name_prefix}-root"
    }
  }

  metadata_options {
    http_endpoint = "enabled"
    http_tokens   = "required"
  }

  lifecycle {
    prevent_destroy = true
    ignore_changes  = [user_data]
  }

  tags = {
    Name = local.name_prefix
  }
}

resource "aws_eip" "ai" {
  domain = "vpc"

  tags = {
    Name = "${local.name_prefix}-eip"
  }
}

resource "aws_eip_association" "ai" {
  instance_id   = aws_instance.ai.id
  allocation_id = aws_eip.ai.id
}
