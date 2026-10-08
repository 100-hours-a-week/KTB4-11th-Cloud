data "aws_ssm_parameter" "ubuntu_2604_ami" {
  name = "/aws/service/canonical/ubuntu/server/resolute/stable/current/amd64/hvm/ebs-gp3/ami-id"
}

resource "aws_instance" "app" {
  ami                         = data.aws_ssm_parameter.ubuntu_2604_ami.value
  instance_type               = var.app_instance_type
  key_name                    = var.ec2_key_name
  subnet_id                   = aws_subnet.public.id
  associate_public_ip_address = true
  vpc_security_group_ids      = [aws_security_group.app.id]
  iam_instance_profile        = aws_iam_instance_profile.app.name

  user_data = templatefile("${path.module}/app_user_data.sh", {
    cloud_repository_url    = "https://github.com/${var.github_repository_owner}/${var.github_cloud_repository_name}.git"
    cloud_repository_branch = var.github_deployment_branch
    docker_compose_version  = var.docker_compose_version
  })

  root_block_device {
    volume_type           = "gp3"
    volume_size           = var.app_root_volume_size_gib
    encrypted             = true
    delete_on_termination = true

    tags = {
      Name        = "${var.name_prefix}-app-root"
      Project     = "stockspoon"
      Environment = "loadtest"
      ManagedBy   = "Terraform"
    }
  }

  metadata_options {
    http_endpoint = "enabled"
    http_tokens   = "required"
  }

  depends_on = [
    aws_route.internet,
    aws_route_table_association.public,
  ]

  lifecycle {
    ignore_changes = [ami]
  }

  tags = {
    Name        = "${var.name_prefix}-app"
    Project     = "stockspoon"
    Environment = "loadtest"
    ManagedBy   = "Terraform"
  }
}

resource "aws_eip" "app" {
  domain = "vpc"

  depends_on = [aws_internet_gateway.loadtest]

  tags = {
    Name        = "${var.name_prefix}-app-eip"
    Project     = "stockspoon"
    Environment = "loadtest"
    ManagedBy   = "Terraform"
  }
}

resource "aws_eip_association" "app" {
  instance_id   = aws_instance.app.id
  allocation_id = aws_eip.app.id
}

resource "aws_instance" "k6" {
  ami                         = data.aws_ssm_parameter.ubuntu_2604_ami.value
  instance_type               = var.k6_instance_type
  key_name                    = var.ec2_key_name
  subnet_id                   = aws_subnet.public.id
  associate_public_ip_address = true
  vpc_security_group_ids      = [aws_security_group.k6.id]
  iam_instance_profile        = aws_iam_instance_profile.k6.name
  user_data                   = file("${path.module}/k6_user_data.sh")

  root_block_device {
    volume_type           = "gp3"
    volume_size           = var.k6_root_volume_size_gib
    encrypted             = true
    delete_on_termination = true

    tags = {
      Name        = "${var.name_prefix}-k6-root"
      Project     = "stockspoon"
      Environment = "loadtest"
      ManagedBy   = "Terraform"
    }
  }

  metadata_options {
    http_endpoint = "enabled"
    http_tokens   = "required"
  }

  depends_on = [
    aws_route.internet,
    aws_route_table_association.public,
  ]

  lifecycle {
    ignore_changes = [
      ami,
      associate_public_ip_address,
    ]
  }

  tags = {
    Name        = "${var.name_prefix}-k6"
    Project     = "stockspoon"
    Environment = "loadtest"
    ManagedBy   = "Terraform"
  }
}
