# 다른 root(app-server)가 소유한 리소스에 ECS가 필요해서 추가하는 규칙
# TODO: V1 종료 또는 ALB를 edge root로 이전할 때 함께 정리

# ALB → Backend Task (ALB SG의 기존 egress는 V1 EC2의 80/443만 허용)
resource "aws_vpc_security_group_egress_rule" "alb_to_backend_task" {
  security_group_id            = data.terraform_remote_state.app.outputs.alb_security_group_id
  referenced_security_group_id = aws_security_group.backend_task.id
  from_port                    = var.backend_container_port
  to_port                      = var.backend_container_port
  ip_protocol                  = "tcp"
  description                  = "Allow application traffic and health checks to ECS backend tasks"
}

# 테스트 헤더가 있는 요청만 Green(ECS)으로 전달한다.
# 기본 action(Blue, V1 EC2)은 변경하지 않으므로 운영 트래픽에는 영향이 없다.
# Canary 배포 단계에서 가중치 규칙으로 교체한다.
resource "aws_lb_listener_rule" "backend_test" {
  listener_arn = data.terraform_remote_state.app.outputs.https_listener_arn
  priority     = var.backend_test_rule_priority

  action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.backend_green.arn
  }

  condition {
    http_header {
      http_header_name = var.backend_test_header_name
      values           = [var.backend_test_header_value]
    }
  }

  tags = {
    Name = "${var.name_prefix}-backend-test"
  }
}
