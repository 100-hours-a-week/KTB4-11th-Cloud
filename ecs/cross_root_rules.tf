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

  # 두 조건을 모두 만족해야 한다. (경로 기반 분리: Backend는 /api/*)
  condition {
    http_header {
      http_header_name = var.backend_test_header_name
      values           = [var.backend_test_header_value]
    }
  }

  condition {
    path_pattern {
      values = var.backend_path_patterns
    }
  }

  tags = {
    Name = "${var.name_prefix}-backend-test"
  }
}

# ---------------------------------------------------------------------------
# market-http (/market/*)
# ---------------------------------------------------------------------------

resource "aws_vpc_security_group_egress_rule" "alb_to_market_http_task" {
  security_group_id            = data.terraform_remote_state.app.outputs.alb_security_group_id
  referenced_security_group_id = aws_security_group.market_http_task.id
  from_port                    = var.market_http_container_port
  to_port                      = var.market_http_container_port
  ip_protocol                  = "tcp"
  description                  = "Allow application traffic and health checks to ECS market-http tasks"
}

# V1에는 /market 경로가 없으므로 헤더 없이 운영 트래픽을 바로 전달한다.
# 앱은 루트 경로(/prices, /prices/stream, /bars/{code})를 제공하므로 /market 접두사를 제거해 전달한다.
#   /market/prices?codes=005930 → /prices?codes=005930
resource "aws_lb_listener_rule" "market_http" {
  listener_arn = data.terraform_remote_state.app.outputs.https_listener_arn
  priority     = var.market_http_rule_priority

  action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.market_http.arn
  }

  condition {
    path_pattern {
      values = ["${var.market_http_path_prefix}/*"]
    }
  }

  transform {
    type = "url-rewrite"

    url_rewrite_config {
      rewrite {
        regex   = "^${var.market_http_path_prefix}/(.*)$"
        replace = "/$1"
      }
    }
  }

  tags = {
    Name = "${var.name_prefix}-market-http"
  }
}

# ---------------------------------------------------------------------------
# V1 AI 운영 서버 (ai-server/infra 소유 SG)
# Compose가 QuestDB를 private IP에만 게시하고, 여기서 market-http Task SG만 허용한다.
# TODO: V2 데이터 저장소로 이전하면 제거
# ---------------------------------------------------------------------------

resource "aws_vpc_security_group_ingress_rule" "ai_questdb_from_market_http" {
  security_group_id            = data.terraform_remote_state.ai.outputs.ai_security_group_id
  referenced_security_group_id = aws_security_group.market_http_task.id
  from_port                    = var.ai_questdb_http_port
  to_port                      = var.ai_questdb_http_port
  ip_protocol                  = "tcp"
  description                  = "Allow V2 market-http tasks to query QuestDB"
}

# ---------------------------------------------------------------------------
# V1 앱 서버 MySQL (app-server 소유 SG)
# V1 Compose가 MySQL을 호스트에 게시하고, 외부 접근은 이 SG 규칙으로만 통제한다.
# TODO: V2 DB로 이전하면 제거
# ---------------------------------------------------------------------------

resource "aws_vpc_security_group_ingress_rule" "v1_mysql_from_backend" {
  security_group_id            = data.terraform_remote_state.app.outputs.app_security_group_id
  referenced_security_group_id = aws_security_group.backend_task.id
  from_port                    = var.v1_mysql_port
  to_port                      = var.v1_mysql_port
  ip_protocol                  = "tcp"
  description                  = "Allow V2 backend tasks to use V1 MySQL"
}

# ProxySQL은 별도 ECS 서비스이며 Backend datasource는 이 단계에서 변경하지 않는다.
resource "aws_vpc_security_group_ingress_rule" "v1_mysql_from_proxysql" {
  security_group_id            = data.terraform_remote_state.app.outputs.app_security_group_id
  referenced_security_group_id = aws_security_group.proxysql_task.id
  from_port                    = var.v1_mysql_port
  to_port                      = var.v1_mysql_port
  ip_protocol                  = "tcp"
  description                  = "Allow the ProxySQL ECS task to reach V1 MySQL"
}
