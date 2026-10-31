# 다른 root 또는 기존 ECS 서비스가 소유한 리소스에 ECS가 필요해서 추가하는 규칙
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

resource "aws_vpc_security_group_ingress_rule" "ai_postgres_from_market_http" {
  security_group_id            = data.terraform_remote_state.ai.outputs.ai_security_group_id
  referenced_security_group_id = aws_security_group.market_http_task.id
  from_port                    = 5432
  to_port                      = 5432
  ip_protocol                  = "tcp"
  description                  = "Allow V2 market-http tasks to query the AI PostgreSQL database"
}


# Backend task SG가 ProxySQL port로 접속할 수 있게 한다.
resource "aws_vpc_security_group_ingress_rule" "proxysql_from_backend" {
  security_group_id            = aws_security_group.proxysql_task.id
  referenced_security_group_id = aws_security_group.backend_task.id
  from_port                    = var.proxysql_port
  to_port                      = var.proxysql_port
  ip_protocol                  = "tcp"
  description                  = "Allow V2 backend tasks to connect to ProxySQL"
}

# The operator-triggered replay Lambda uses the same private ProxySQL endpoint
# as Backend tasks after the promoted writer is ready.
resource "aws_vpc_security_group_ingress_rule" "proxysql_from_db_write_replay_lambda" {
  security_group_id            = aws_security_group.proxysql_task.id
  referenced_security_group_id = data.terraform_remote_state.messaging_prod.outputs.db_write_replay_lambda_security_group_id
  from_port                    = var.proxysql_port
  to_port                      = var.proxysql_port
  ip_protocol                  = "tcp"
  description                  = "Allow the DB write replay Lambda to execute queued writes through ProxySQL"
}

# Allow only the rehearsal Prometheus host to scrape Fargate ProxySQL metrics.
resource "aws_vpc_security_group_ingress_rule" "proxysql_metrics_from_pmm" {
  count = var.proxysql_fargate_enabled && local.proxysql_pmm_security_group_id != "" ? 1 : 0

  security_group_id            = aws_security_group.proxysql_task.id
  referenced_security_group_id = local.proxysql_pmm_security_group_id
  from_port                    = 6070
  to_port                      = 6070
  ip_protocol                  = "tcp"
  description                  = "Allow the rehearsal Prometheus host to scrape Fargate ProxySQL metrics"
}

# The PMM/PLG host uses restrictive egress rules, so allow its Prometheus
# container to reach only the ProxySQL task security group on the metrics port.
resource "aws_vpc_security_group_egress_rule" "pmm_to_proxysql_metrics" {
  count = var.proxysql_fargate_enabled && local.proxysql_pmm_security_group_id != "" ? 1 : 0

  security_group_id            = local.proxysql_pmm_security_group_id
  referenced_security_group_id = aws_security_group.proxysql_task.id
  from_port                    = 6070
  to_port                      = 6070
  ip_protocol                  = "tcp"
  description                  = "Allow Prometheus to scrape Fargate ProxySQL metrics"
}
