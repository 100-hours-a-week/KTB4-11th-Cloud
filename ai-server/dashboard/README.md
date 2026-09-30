# AI server CloudWatch dashboard

이 Terraform은 시스템 상태와 함께 다음 애플리케이션 지표를 표시합니다.

- 최근 4시간 뉴스 수집 성공/실패 및 임베딩 건수
- 최근 4시간 뉴스 수집 실패 로그
- 관리 중인 계좌 수
- 최근 7일 모델 포트폴리오 생성 수 (`0`이면 생성 내역 없음)
- vLLM prefill TPS, KV cache 사용률, prefix cache hit rate, 대기/실행 요청 수

뉴스 지표와 실패 로그는 `/stockspoon/ai/application`의 구조화된 로그를 Logs Insights로 직접 집계합니다. 로그 그룹은 `application_log_group` 변수로 변경할 수 있습니다.

나머지 위젯은 아래의 dimension 없는 CloudWatch custom metric을 기대합니다. 실제 수집 설정의 네임스페이스가 다르면 Terraform 변수만 변경하면 됩니다.

| Namespace 변수 | Metric | 단위/의미 |
| --- | --- | --- |
| `business_metric_namespace` | `ManagedAccounts` | 현재 관리 중인 계좌 수 gauge |
| `business_metric_namespace` | `ModelPortfoliosCreated` | 포트폴리오 생성 때마다 1 증가하는 count |
| `vllm_metric_namespace` | `vllm:prompt_tokens_total` | 누적 prefill token counter |
| `vllm_metric_namespace` | `vllm:kv_cache_usage_perc` | 0~1 KV cache 사용률 gauge |
| `vllm_metric_namespace` | `vllm:prefix_cache_hits` | 누적 prefix cache hit counter |
| `vllm_metric_namespace` | `vllm:prefix_cache_queries` | 누적 prefix cache query counter |
| `vllm_metric_namespace` | `vllm:num_requests_waiting` | 대기 요청 수 gauge |
| `vllm_metric_namespace` | `vllm:num_requests_running` | 실행 요청 수 gauge |

기본 네임스페이스는 각각 `Stockspoon/AI`, `Stockspoon/vLLM`입니다. 현재 AWS 계정에는 이 custom metric들이 아직 발행되지 않으므로 수집기 또는 애플리케이션 발행 설정이 먼저 필요합니다.
