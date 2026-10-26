# ---------------------------------------------------------------------------
# ECS Cluster
# ---------------------------------------------------------------------------

resource "aws_ecs_cluster" "main" {
  name = "${var.name_prefix}-cluster"

  # 부하테스트 시 Task·Service 단위 CPU/Memory 지표 수집
  setting {
    name  = "containerInsights"
    value = "enabled"
  }
}

# ---------------------------------------------------------------------------
# Service ASG (Backend + Socket)
# ---------------------------------------------------------------------------

# 최신 ECS 최적화 Amazon Linux 2023 AMI
data "aws_ssm_parameter" "ecs_ami" {
  name = "/aws/service/ecs/optimized-ami/amazon-linux-2023/recommended/image_id"
}

# 컨테이너 인스턴스 자체에는 인바운드를 열지 않는다.
# awsvpc 모드에서 Task 트래픽은 Task별 ENI와 Task Security Group으로 들어온다.
resource "aws_security_group" "ecs_instance" {
  name        = "${var.name_prefix}-ecs-instance-sg"
  description = "ECS container instances (no inbound; tasks use their own ENIs)"
  vpc_id      = data.terraform_remote_state.shared.outputs.vpc_id

  tags = {
    Name = "${var.name_prefix}-ecs-instance-sg"
  }
}

# 클러스터 등록, 이미지 Pull, 로그 전송 (NAT / S3 Gateway Endpoint 경유)
resource "aws_vpc_security_group_egress_rule" "ecs_instance_all" {
  security_group_id = aws_security_group.ecs_instance.id
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "-1"
  description       = "Allow outbound for ECS agent, image pulls, and logs"
}

resource "aws_launch_template" "service" {
  name                   = "${var.name_prefix}-ecs-service"
  image_id               = var.service_ami_id != null ? var.service_ami_id : data.aws_ssm_parameter.ecs_ami.value
  instance_type          = var.service_instance_type
  vpc_security_group_ids = [aws_security_group.ecs_instance.id]

  iam_instance_profile {
    name = aws_iam_instance_profile.ecs_instance.name
  }

  # IMDSv2 강제
  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "required"
    http_put_response_hop_limit = 1
  }

  block_device_mappings {
    device_name = "/dev/xvda"

    ebs {
      volume_type           = "gp3"
      volume_size           = var.service_root_volume_size_gib
      encrypted             = true
      delete_on_termination = true
    }
  }

  # ECS_AWSVPC_BLOCK_IMDS: Task가 인스턴스 Role 자격 증명을 가져가지 못하게 막는다.
  user_data = base64encode(<<-EOT
    #!/bin/bash
    cat >> /etc/ecs/ecs.config <<'CONFIG'
    ECS_CLUSTER=${aws_ecs_cluster.main.name}
    ECS_CONTAINER_STOP_TIMEOUT=${var.ecs_container_stop_timeout_seconds}s
    ECS_AWSVPC_BLOCK_IMDS=true
    ECS_ENABLE_CONTAINER_METADATA=true
    CONFIG
  EOT
  )

  tag_specifications {
    resource_type = "instance"

    tags = {
      Name = "${var.name_prefix}-ecs-service"
    }
  }

  tag_specifications {
    resource_type = "volume"

    tags = {
      Name = "${var.name_prefix}-ecs-service"
    }
  }
}

resource "aws_autoscaling_group" "service" {
  name                = "${var.name_prefix}-ecs-service"
  vpc_zone_identifier = data.terraform_remote_state.shared.outputs.private_subnet_ids
  min_size            = var.service_asg_min_size
  max_size            = var.service_asg_max_size
  desired_capacity    = var.service_asg_min_size
  health_check_type   = "EC2"
  metrics_granularity = "1Minute"
  enabled_metrics = [
    "GroupMinSize", "GroupMaxSize", "GroupDesiredCapacity",
    "GroupInServiceInstances", "GroupPendingInstances", "GroupTerminatingInstances",
    "GroupTotalInstances",
  ]

  # Managed Termination Protection을 쓰려면 필수
  protect_from_scale_in = true

  launch_template {
    id      = aws_launch_template.service.id
    version = aws_launch_template.service.latest_version
  }

  # ECS Capacity Provider가 관리하는 ASG임을 표시
  tag {
    key                 = "AmazonECSManaged"
    value               = "true"
    propagate_at_launch = true
  }

  tag {
    key                 = "Name"
    value               = "${var.name_prefix}-ecs-service"
    propagate_at_launch = true
  }

  lifecycle {
    # Managed Scaling이 바꾼 desired 값을 apply 때마다 되돌리지 않도록 한다.
    ignore_changes = [desired_capacity]
  }
}

resource "aws_ecs_capacity_provider" "service" {
  name = "${var.name_prefix}-service"

  auto_scaling_group_provider {
    auto_scaling_group_arn         = aws_autoscaling_group.service.arn
    managed_termination_protection = "ENABLED"
    managed_draining               = "ENABLED"

    managed_scaling {
      status                    = "ENABLED"
      target_capacity           = var.service_target_capacity
      minimum_scaling_step_size = 1
      maximum_scaling_step_size = 1
      instance_warmup_period    = 300
    }
  }
}

resource "aws_ecs_cluster_capacity_providers" "main" {
  cluster_name       = aws_ecs_cluster.main.name
  capacity_providers = [aws_ecs_capacity_provider.service.name]

  default_capacity_provider_strategy {
    capacity_provider = aws_ecs_capacity_provider.service.name
    weight            = 1
    base              = 0
  }
}
