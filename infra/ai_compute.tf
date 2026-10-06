# Dedicated Ubuntu host for AI containers in the existing public subnet/VPC.
# The instance keeps subnet-level public IPv4 assignment enabled to avoid
# replacing the existing host; the Elastic IP below becomes its stable public
# address after association.
resource "aws_instance" "ai" {
  ami                         = data.aws_ssm_parameter.ubuntu_2604_ami.value
  instance_type               = var.ai_ec2_instance_type
  key_name                    = var.ec2_key_name
  subnet_id                   = aws_subnet.public.id
  associate_public_ip_address = true
  iam_instance_profile        = aws_iam_instance_profile.ai_ec2.name
  vpc_security_group_ids      = [aws_security_group.ai.id]

  user_data = templatefile("${path.module}/ai_user_data.sh", {
    docker_compose_version = var.docker_compose_version
  })

  root_block_device {
    volume_type           = "gp3"
    volume_size           = var.ai_ec2_root_volume_size_gib
    encrypted             = true
    delete_on_termination = true

    tags = {
      Name        = "stockspoon-v1-ai-root"
      Project     = "stockspoon"
      Environment = "v1"
      ManagedBy   = "Terraform"
    }
  }

  metadata_options {
    http_endpoint = "enabled"
    http_tokens   = "required"
  }

  depends_on = [aws_route_table_association.public]

  tags = {
    Name        = "stockspoon-v1-ai-app"
    Project     = "stockspoon"
    Environment = "v1"
    ManagedBy   = "Terraform"
  }
}

# Stable public address
resource "aws_eip" "ai" {
  domain = "vpc"

  depends_on = [aws_internet_gateway.main]

  tags = {
    Name        = "stockspoon-v1-ai-eip"
    Project     = "stockspoon"
    Environment = "v1"
    ManagedBy   = "Terraform"
  }
}

resource "aws_eip_association" "ai" {
  instance_id   = aws_instance.ai.id
  allocation_id = aws_eip.ai.id
}
