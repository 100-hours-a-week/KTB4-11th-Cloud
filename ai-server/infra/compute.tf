# 기존 공통 VPC의 public subnet에서 AI 컨테이너를 실행하는 EC2입니다.
resource "aws_instance" "ai" {
  # 빈 destination state에서 import plan을 만들 때 ForceNew 필드가 unknown이
  # 되지 않도록 기존 AMI를 사용합니다. Migration 완료 후 SSM 조회로 복원합니다.
  ami                         = local.migration_ai_ami_id
  instance_type               = var.ai_ec2_instance_type
  key_name                    = var.ec2_key_name
  subnet_id                   = data.terraform_remote_state.core.outputs.public_subnet_id
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
  # 빈 destination state에서도 기존 association을 순수 import할 수 있게 고정합니다.
  instance_id   = local.migration_ai_instance_id
  allocation_id = aws_eip.ai.id
}
