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
| 시스템 지표 수집 중단 | CloudWatch Agent CPU 지표가 5분 연속 누락 |
| 필수 컨테이너 장애 | `postgres` 또는 `questdb`가 2분 연속 실행·헬스체크 실패하거나 모니터 지표가 누락 |
| 메모리 사용률 | 85% 이상, 최근 5분 중 3분 |
| 루트 디스크 사용률 | 85% 이상, 5분 연속 |
| EC2 상태 검사 | 실패 상태가 2분 연속 |
| 스토리지 장치 오류 | 최근 5분에 1건 이상 |
| 애플리케이션 오류 로그 | 최근 5분에 5건 이상 |
| 시장 데이터 수집 실패 | 예약된 단발 수집 작업의 최종 실패 |
| 뉴스 전처리 스케줄 실패 | systemd 재시도를 모두 소진한 최종 실패 |
| 시장 데이터 동기화 스케줄 실패 | systemd 재시도를 모두 소진한 최종 실패 |
| 장 시작 전 파이프라인 실패 | 평일 오전 파이프라인의 최종 실패 |
| 포트폴리오 리밸런싱 실패 | systemd 재시도를 모두 소진한 최종 실패 |

시스템 지표 수집 중단 및 필수 컨테이너 장애 알람은 데이터 누락을 장애로 간주하고, 나머지 알람은 데이터가 없을 때 정상으로 간주합니다. 장애 상태 진입 시 `ALARM` 알림을 전송하고 직전 상태가 `ALARM`이었던 알람이 정상으로 복구되면 `OK` 알림을 전송합니다. 알람 생성 직후 `INSUFFICIENT_DATA`에서 `OK`로 바뀌는 경우처럼 실제 장애가 없었던 `OK` 전환은 Lambda가 알리지 않습니다. 복구 알림에는 Docker 진단 정보를 첨부하지 않습니다.

CPU·메모리 또는 이름에 `container`가 포함된 알람이 `ALARM` 상태로 진입하면 알림 Lambda가 AI EC2에서 SSM Run Command로 `docker ps -a`와 `docker stats --no-stream`을 실행합니다. 전체 컨테이너의 상태·이미지와 실행 중인 컨테이너의 CPU·메모리·네트워크·블록 I/O·PID 정보를 같은 Discord 메시지에 첨부합니다. SSM 또는 Docker가 응답하지 않아도 수집 실패 원인을 첨부하고 원래 장애 알림은 계속 전송합니다. 이를 위해 AI EC2 역할에는 `AmazonSSMManagedInstanceCore`가 연결되며 인스턴스에서 SSM Agent가 실행 중이어야 합니다.

필수 컨테이너 장애 감시는 AI EC2의 systemd timer가 1분마다 실행합니다. Compose 프로젝트 `ktb4-ai`에서 서비스 라벨이 `postgres` 또는 `questdb`인 실행 중인 컨테이너를 찾아 Docker health 상태가 `healthy`인지 확인하고, 결과를 `AI_CWAgent/ContainerFailureCount`로 발행합니다. 스케줄 컨테이너는 감시 대상에 포함하지 않습니다. EC2에 복사할 스크립트와 systemd 원본은 저장소 루트의 `scripts copy`와 `infrastructure/systemd`에 있습니다.

`ktb-market-collector.timer`, `ktb-news-preprocessor.timer`, `ktb-market-syncer.timer`, `ktb-morning-pipeline.timer`, `ktb-portfolio-rebalancer.timer`의 작업 결과는 각 service의 systemd 훅으로 감시합니다. 성공하면 `AI_CWAgent/ScheduledJobFailure`에 `0`을 발행하고, 설정된 재시도를 모두 소진해 최종 실패하면 `OnFailure`가 `1`을 발행합니다. 작업별 알람은 누락 데이터를 무시해 실패 상태를 유지하고, 다음 실행이 실제로 성공해 `0`이 들어왔을 때만 `OK` 복구 알림을 전송합니다.

훅 unit(`ktb-scheduled-job-success@.service`, `ktb-scheduled-job-failure@.service`)과 발행 스크립트(`scripts/publish-scheduled-job-metric.sh`)는 AI 저장소에 있으며 AI CD가 작업 service와 함께 설치합니다. 재시도가 있는 작업(`Restart=on-failure`)은 `RestartMode=direct`(systemd 254 이상)를 사용합니다. 기본값인 `normal`은 재시도할 때마다 `failed` 상태를 거치므로 중간 실패에도 `OnFailure`가 실행되기 때문입니다. 스크립트는 IMDSv2로 인스턴스 ID를 조회하고 AWS CLI v2(`/usr/local/bin/aws`)로 지표를 발행합니다. 따라서 AI EC2에 AWS CLI v2가 설치돼 있어야 하며, 없으면 AI CD가 운영 파일을 바꾸기 전에 실패합니다.

Terraform은 `stockspoon/v1/ai/discord-webhook` Secret 리소스만 생성하며 Webhook 값은 state에 저장하지 않습니다. 최초 apply 후, 채팅에 노출되지 않은 새 Webhook URL을 AWS 콘솔 또는 CLI로 Secret에 직접 저장해야 합니다.
