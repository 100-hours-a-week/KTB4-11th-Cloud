# 공통 public subnet에서 AI 컨테이너를 실행하는 EC2입니다.
resource "aws_instance" "ai" {
  # 운영 인스턴스가 최신 AMI 조회 결과 변경만으로 교체되지 않도록 AMI를 고정합니다.
  ami                         = var.ai_ec2_ami_id
  instance_type               = var.ai_ec2_instance_type
  key_name                    = var.ec2_key_name
  subnet_id                   = data.terraform_remote_state.shared.outputs.public_subnet_id
  associate_public_ip_address = true
  iam_instance_profile        = aws_iam_instance_profile.ai_ec2.name
  vpc_security_group_ids      = [aws_security_group.ai.id]

  user_data = templatefile("${path.module}/templates/user-data.sh", {
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

  lifecycle {
    prevent_destroy = true
    ignore_changes  = [user_data]
  }

  tags = {
    Name        = "stockspoon-v1-ai-app"
    Project     = "stockspoon"
    Environment = "v1"
    ManagedBy   = "Terraform"
  }
}

resource "aws_eip" "ai" {
  domain = "vpc"

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
