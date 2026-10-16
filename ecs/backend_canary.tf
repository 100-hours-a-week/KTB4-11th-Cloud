# 운영 /api/* 요청을 V1(Blue)과 V2(Green)에 가중치로 분배한다.
# 헤더 조건이나 경로 rewrite 없이 원래 URI를 각 타깃 그룹으로 전달한다.
# 기존 priority 100 규칙을 재사용해 생성·삭제 순서에 따른 우선순위 충돌을 피한다.
moved {
  from = aws_lb_listener_rule.backend_test
  to   = aws_lb_listener_rule.backend_canary[0]
}

resource "aws_lb_listener_rule" "backend_canary" {
  count = var.backend_canary_enabled ? 1 : 0

  listener_arn = data.terraform_remote_state.app.outputs.https_listener_arn
  priority     = var.backend_canary_rule_priority

  action {
    type = "forward"

    forward {
      target_group {
        arn    = data.terraform_remote_state.app.outputs.blue_target_group_arn
        weight = 100 - local.backend_effective_green_weight
      }

      target_group {
        arn    = aws_lb_target_group.backend_green.arn
        weight = local.backend_effective_green_weight
      }

      # 한 계정으로 보내는 요청도 설정한 가중치에 따라 양쪽으로 분배한다.
      stickiness {
        enabled  = false
        duration = 1
      }
    }
  }

  condition {
    path_pattern {
      values = var.backend_path_patterns
    }
  }

  tags = {
    Name = "${var.name_prefix}-backend-canary"
  }
}
