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

## 장애 알림

다음 AI 서버 장애 알람을 생성하고 AI 전용 `stockspoon-v1-ai-discord-notifier` Lambda를 호출합니다. App 서버와 Discord 채널을 공유하지 않습니다.

| 알람 | 조건 |
| --- | --- |
| CPU 사용률 | 85% 이상, 최근 5분 중 3분 |
| 메모리 사용률 | 85% 이상, 최근 5분 중 3분 |
| 루트 디스크 사용률 | 85% 이상, 5분 연속 |
| EC2 상태 검사 | 실패 상태가 2분 연속 |
| 스토리지 장치 오류 | 최근 5분에 1건 이상 |
| 애플리케이션 오류 로그 | 최근 5분에 5건 이상 |

모든 알람은 데이터가 없을 때 정상으로 간주합니다. 현재 구성은 장애 상태 진입 알림만 전송하며 정상 복구 알림은 전송하지 않습니다.

Terraform은 `stockspoon/v1/ai/discord-webhook` Secret 리소스만 생성하며 Webhook 값은 state에 저장하지 않습니다. 최초 apply 후, 채팅에 노출되지 않은 새 Webhook URL을 AWS 콘솔 또는 CLI로 Secret에 직접 저장해야 합니다.
