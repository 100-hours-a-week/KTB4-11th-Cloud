# AI 지표 네임스페이스와 대시보드 위젯 공통 설정을 정의합니다.
locals {
  namespace                 = "AI_CWAgent"
  business_metric_namespace = var.business_metric_namespace
  vllm_metric_namespace     = var.vllm_metric_namespace

  widget_defaults = {
    region = var.aws_region
    width  = 12
    height = 6
    period = 60
    view   = "timeSeries"
  }
}

# AI 서버의 기본 시스템 지표를 표시하는 CloudWatch 대시보드를 생성합니다.
resource "aws_cloudwatch_dashboard" "ai_basic" {
  dashboard_name = var.dashboard_name

  dashboard_body = jsonencode({
    start          = "-PT4H"
    periodOverride = "inherit"
    widgets = [
      # AI 서버 전체 CPU의 평균 사용률을 표시합니다.
      {
        type = "metric"
        x    = 0
        y    = 0
        properties = merge(local.widget_defaults, {
          title = "AI CPU 사용률"
          stat  = "Average"
          yAxis = { left = { min = 0, max = 100 } }
          metrics = [
            [local.namespace, "cpu_usage_active", "InstanceId", var.ai_instance_id, "InstanceType", var.ai_instance_type, "cpu", "cpu-total", { label = "CPU active", color = "#d62728" }]
          ]
        })
      },
      # AI 서버의 메모리 사용률과 가용률을 함께 표시합니다.
      {
        type = "metric"
        x    = 12
        y    = 0
        properties = merge(local.widget_defaults, {
          title = "AI 메모리"
          stat  = "Average"
          yAxis = { left = { min = 0, max = 100 } }
          metrics = [
            [local.namespace, "mem_used_percent", "InstanceId", var.ai_instance_id, "InstanceType", var.ai_instance_type, { label = "사용", color = "#ff7f0e" }],
            [".", "mem_available_percent", ".", ".", ".", ".", { label = "가용", color = "#2ca02c" }]
          ]
        })
      },
      # AI 서버 루트 파일 시스템의 디스크 사용률을 표시합니다.
      {
        type = "metric"
        x    = 0
        y    = 6
        properties = merge(local.widget_defaults, {
          title = "AI 루트 디스크 사용률"
          stat  = "Average"
          yAxis = { left = { min = 0, max = 100 } }
          metrics = [
            [local.namespace, "disk_used_percent", "InstanceId", var.ai_instance_id, "InstanceType", var.ai_instance_type, "path", "/", "fstype", "ext4", { label = "/ 사용률", color = "#9467bd" }]
          ]
        })
      },
      # AI EC2 인스턴스의 네트워크 송수신량을 표시합니다.
      {
        type = "metric"
        x    = 12
        y    = 6
        properties = merge(local.widget_defaults, {
          title = "AI 네트워크 송수신"
          stat  = "Sum"
          metrics = [
            ["AWS/EC2", "NetworkIn", "InstanceId", var.ai_instance_id, { label = "수신", color = "#1f77b4" }],
            [".", "NetworkOut", ".", ".", { label = "송신", color = "#ff7f0e" }]
          ]
        })
      },
      # AI EC2 인스턴스와 기반 시스템의 상태 검사 실패 여부를 표시합니다.
      {
        type   = "metric"
        x      = 0
        y      = 12
        width  = 24
        height = 5
        properties = {
          title  = "AI EC2 상태 검사"
          region = var.aws_region
          view   = "timeSeries"
          stat   = "Maximum"
          period = 60
          yAxis  = { left = { min = 0, max = 1 } }
          metrics = [
            ["AWS/EC2", "StatusCheckFailed", "InstanceId", var.ai_instance_id, { label = "전체", color = "#d62728" }],
            [".", "StatusCheckFailed_Instance", ".", ".", { label = "인스턴스", color = "#ff7f0e" }],
            [".", "StatusCheckFailed_System", ".", ".", { label = "시스템", color = "#9467bd" }]
          ]
        }
      },
      # 구조화된 애플리케이션 로그에서 최근 4시간의 뉴스 처리 건수를 집계합니다.
      {
        type   = "log"
        x      = 0
        y      = 18
        width  = 12
        height = 6
        properties = {
          title  = "뉴스 처리 현황 (최근 4시간)"
          region = var.aws_region
          view   = "table"
          query = join("\n", [
            "SOURCE '${var.application_log_group}'",
            "| fields logger, message",
            "| parse message '*: * feed entries, * new articles, * failed' as scrape_source, feed_count, collected_count, failed_count",
            "| parse message 'embedded * articles' as embedded_count",
            "| filter logger in ['news_preprocessor.scrape', 'news_preprocessor.embed_pending']",
            "| stats sum(collected_count) as collection_succeeded, sum(failed_count) as collection_failed, sum(embedded_count) as embedded"
          ])
        }
      },
      # 관리 중인 계좌 수는 애플리케이션이 발행하는 최신 gauge 값을 표시합니다.
      {
        type   = "metric"
        x      = 12
        y      = 18
        width  = 6
        height = 6
        properties = {
          title     = "관리 중인 계좌 수"
          region    = var.aws_region
          view      = "singleValue"
          stat      = "Maximum"
          period    = 60
          sparkline = true
          metrics = [
            [local.business_metric_namespace, "ManagedAccounts", { label = "계좌", color = "#1f77b4" }]
          ]
        }
      },
      # 최근 7일간 생성된 모델 포트폴리오 수를 표시합니다. 0이면 생성된 포트폴리오가 없습니다.
      {
        type   = "metric"
        x      = 18
        y      = 18
        width  = 6
        height = 6
        properties = {
          title                = "최근 7일 모델 포트폴리오 생성"
          region               = var.aws_region
          view                 = "singleValue"
          stat                 = "Sum"
          period               = 60
          start                = "-P7D"
          setPeriodToTimeRange = true
          metrics = [
            [local.business_metric_namespace, "ModelPortfoliosCreated", { id = "portfolio_created", visible = false }],
            [{ expression = "FILL(portfolio_created, 0)", id = "portfolio_created_filled", label = "생성 수", color = "#2ca02c" }]
          ]
        }
      },
      # 수집에 실패한 뉴스 배치 로그를 원인 파악이 가능한 테이블로 표시합니다.
      {
        type   = "log"
        x      = 0
        y      = 24
        width  = 24
        height = 7
        properties = {
          title  = "뉴스 수집 실패 로그 (최근 4시간)"
          region = var.aws_region
          view   = "table"
          query = join("\n", [
            "SOURCE '${var.application_log_group}'",
            "| fields @timestamp, logger, message",
            "| filter logger = 'news_preprocessor.scrape'",
            "| parse message '*: * feed entries, * new articles, * failed' as scrape_source, feed_count, collected_count, failed_count",
            "| filter failed_count > 0 or level in ['ERROR', 'CRITICAL']",
            "| display @timestamp, scrape_source, failed_count, message",
            "| sort @timestamp desc",
            "| limit 100"
          ])
        }
      },
      # 누적 prompt token counter의 분당 변화율을 prefill TPS로 환산합니다.
      {
        type   = "metric"
        x      = 0
        y      = 31
        width  = 8
        height = 6
        properties = merge(local.widget_defaults, {
          title = "vLLM Prefill TPS"
          stat  = "Maximum"
          metrics = [
            [local.vllm_metric_namespace, "vllm:prompt_tokens_total", { id = "prompt_tokens", visible = false }],
            [{ expression = "IF(RATE(prompt_tokens) >= 0, RATE(prompt_tokens), 0)", id = "prefill_tps", label = "tokens/s", color = "#1f77b4" }]
          ]
        })
      },
      # vLLM KV cache 사용률은 0~1 gauge를 백분율로 변환해 표시합니다.
      {
        type   = "metric"
        x      = 8
        y      = 31
        width  = 8
        height = 6
        properties = merge(local.widget_defaults, {
          title = "vLLM KV cache usage"
          stat  = "Average"
          yAxis = { left = { min = 0, max = 100 } }
          metrics = [
            [local.vllm_metric_namespace, "vllm:kv_cache_usage_perc", { id = "kv_cache", visible = false }],
            [{ expression = "100 * kv_cache", id = "kv_cache_percent", label = "KV cache (%)", color = "#9467bd" }]
          ]
        })
      },
      # prefix cache의 query 대비 hit 증가율을 백분율로 표시합니다.
      {
        type   = "metric"
        x      = 16
        y      = 31
        width  = 8
        height = 6
        properties = merge(local.widget_defaults, {
          title = "vLLM Prefill cache hit rate"
          stat  = "Maximum"
          yAxis = { left = { min = 0, max = 100 } }
          metrics = [
            [local.vllm_metric_namespace, "vllm:prefix_cache_hits", { id = "cache_hits", visible = false }],
            [".", "vllm:prefix_cache_queries", { id = "cache_queries", visible = false }],
            [{ expression = "IF(RATE(cache_queries) > 0, IF(RATE(cache_hits) >= 0, 100 * RATE(cache_hits) / RATE(cache_queries), 0), 0)", id = "cache_hit_rate", label = "hit rate (%)", color = "#2ca02c" }]
          ]
        })
      },
      # vLLM 스케줄러에서 실행 중이거나 대기 중인 요청 수를 함께 표시합니다.
      {
        type   = "metric"
        x      = 0
        y      = 37
        width  = 24
        height = 6
        properties = merge(local.widget_defaults, {
          title = "vLLM 요청 상태"
          stat  = "Maximum"
          yAxis = { left = { min = 0 } }
          metrics = [
            [local.vllm_metric_namespace, "vllm:num_requests_waiting", { label = "waiting", color = "#ff7f0e" }],
            [".", "vllm:num_requests_running", { label = "running", color = "#1f77b4" }]
          ]
        })
      }
    ]
  })
}
