# Resolve the latest official Ubuntu Server 26.04 LTS x86_64 AMI published by
# Canonical for the selected AWS region. t3a instances use x86_64.
data "aws_ssm_parameter" "ubuntu_2604_ami" {
  name = "/aws/service/canonical/ubuntu/server/resolute/stable/current/amd64/hvm/ebs-gp3/ami-id"
}

# Single V1 application host for Nginx, frontend, backend, MySQL, and Redis.
resource "aws_instance" "app" {
  ami                    = data.aws_ssm_parameter.ubuntu_2604_ami.value
  instance_type          = var.ec2_instance_type
  key_name               = var.ec2_key_name
  subnet_id              = aws_subnet.public.id
  vpc_security_group_ids = [aws_security_group.app.id]

  user_data = templatefile("${path.module}/user-data.sh", {
    cloud_repository_url    = "https://github.com/${var.github_repository_owner}/${var.github_cloud_repository_name}.git"
    cloud_repository_branch = var.github_deployment_branch
    docker_compose_version  = var.docker_compose_version
  })

  # Docker images, named volumes, and MySQL data are stored on this root EBS.
  # No additional data EBS volume is created for V1.
  root_block_device {
    volume_type           = "gp3"
    volume_size           = var.ec2_root_volume_size_gib
    encrypted             = true
    delete_on_termination = true

    tags = {
      Name        = "stockspoon-v1-app-root"
      Project     = "stockspoon"
      Environment = "v1"
      ManagedBy   = "Terraform"
    }
  }

  metadata_options {
    http_endpoint = "enabled"
    http_tokens   = "required"
  }

  # The SSM parameter points to Canonical's newest 26.04 image. Do not replace
  # this stateful V1 host automatically whenever Canonical publishes a new AMI.
  lifecycle {
    ignore_changes = [ami]
  }

  tags = {
    Name        = "stockspoon-v1-app"
    Project     = "stockspoon"
    Environment = "v1"
    ManagedBy   = "Terraform"
  }
}

# Stable public address used by GitHub Actions as the EC2_HOST secret.
resource "aws_eip" "app" {
  domain = "vpc"

  depends_on = [aws_internet_gateway.main]

  tags = {
    Name        = "stockspoon-v1-app-eip"
    Project     = "stockspoon"
    Environment = "v1"
    ManagedBy   = "Terraform"
  }
}

resource "aws_eip_association" "app" {
  instance_id   = aws_instance.app.id
  allocation_id = aws_eip.app.id
}
