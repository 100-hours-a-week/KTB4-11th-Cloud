resource "aws_cloudwatch_log_group" "performance" {
  name              = "/aws/ecs/containerinsights/${aws_ecs_cluster.main.name}/performance"
  retention_in_days = var.observability_log_retention_days
}

# 기존 ECS가 자동 생성한 로그 그룹을 삭제·재생성하지 않고 관리 대상으로 가져온다.
import {
  to = aws_cloudwatch_log_group.performance
  id = "/aws/ecs/containerinsights/${var.name_prefix}-cluster/performance"
}

resource "aws_cloudwatch_log_group" "lifecycle" {
  name              = "/aws/events/${var.name_prefix}/lifecycle"
  retention_in_days = var.observability_log_retention_days
}

resource "aws_cloudwatch_log_group" "experiments" {
  name              = "/stockspoon/${var.name_prefix}/experiments"
  retention_in_days = var.observability_log_retention_days
}

resource "aws_cloudwatch_event_rule" "ecs_lifecycle" {
  name        = "${var.name_prefix}-ecs-lifecycle"
  description = "Retain ECS task, container instance, service and deployment events"
  event_pattern = jsonencode({
    source        = ["aws.ecs"]
    "detail-type" = ["ECS Task State Change", "ECS Container Instance State Change", "ECS Service Action"]
    detail        = { clusterArn = [aws_ecs_cluster.main.arn] }
  })
}

# 배포 이벤트에는 detail.clusterArn이 없어 서비스 ARN으로 필터링한다.
resource "aws_cloudwatch_event_rule" "ecs_deployment" {
  name        = "${var.name_prefix}-ecs-deployment"
  description = "Retain ECS deployments and rollbacks without requiring detail.clusterArn"
  event_pattern = jsonencode({
    source        = ["aws.ecs"]
    "detail-type" = ["ECS Deployment State Change"]
    resources = [
      { prefix = "arn:${local.partition}:ecs:${var.aws_region}:${local.account_id}:service/${aws_ecs_cluster.main.name}/" }
    ]
  })
}

resource "aws_cloudwatch_event_rule" "asg_lifecycle" {
  name        = "${var.name_prefix}-asg-lifecycle"
  description = "Retain shared service ASG launch and termination outcomes"
  event_pattern = jsonencode({
    source        = ["aws.autoscaling"]
    "detail-type" = ["EC2 Instance Launch Successful", "EC2 Instance Launch Unsuccessful", "EC2 Instance Terminate Successful", "EC2 Instance Terminate Unsuccessful"]
    detail        = { AutoScalingGroupName = [aws_autoscaling_group.service.name] }
  })
}

data "aws_iam_policy_document" "lifecycle_delivery" {
  statement {
    actions   = ["logs:CreateLogStream", "logs:PutLogEvents"]
    resources = ["${aws_cloudwatch_log_group.lifecycle.arn}:*"]
    principals {
      type        = "Service"
      identifiers = ["events.amazonaws.com", "delivery.logs.amazonaws.com"]
    }
  }
}

resource "aws_cloudwatch_log_resource_policy" "lifecycle_delivery" {
  policy_name     = "${var.name_prefix}-lifecycle-delivery"
  policy_document = data.aws_iam_policy_document.lifecycle_delivery.json
}

resource "aws_cloudwatch_event_target" "lifecycle" {
  for_each = {
    ecs        = aws_cloudwatch_event_rule.ecs_lifecycle.name
    deployment = aws_cloudwatch_event_rule.ecs_deployment.name
    asg        = aws_cloudwatch_event_rule.asg_lifecycle.name
  }

  rule      = each.value
  target_id = "cloudwatch-lifecycle"
  arn       = aws_cloudwatch_log_group.lifecycle.arn

  depends_on = [aws_cloudwatch_log_resource_policy.lifecycle_delivery]
}
