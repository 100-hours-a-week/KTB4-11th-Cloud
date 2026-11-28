# DB FIS 관측과 복구 측정

Issue: https://github.com/100-hours-a-week/KTB4-11th-Cloud/issues/352

## 운영 점검 결과 — 2026-11-28 KST

운영 Prometheus를 읽기 전용으로 점검했다. Hikari pending/timeout은 Backend Task 두 개에서 수집되며 acquire histogram은 138개 시계열이었다. ProxySQL 연결 획득 실패 counter, MySQL read_only 두 노드, Replica I/O·SQL thread가 수집된다. 점검 당시 pending/timeout과 ProxySQL 연결 실패는 0, writer 수는 1, Replica I/O·SQL thread와 Semi-sync source/replica 실제 STATUS는 모두 1이었다. 이 값은 점검 시점 관측이며 복구 실험 결과가 아니다.

Repman Task는 RUNNING이지만 양쪽 MySQL에 `ErrorAuth`를 반복 기록하고 있었다. 이는 MySQL Semi-sync 자체의 중단과 구분해야 한다. Task revision 4의 startup command에는 `$$REPMAN_...` 참조 8개가 있었다. POSIX shell의 `$$`는 PID이므로 환경 변수의 비밀번호가 TOML에 전달되지 않는 오류다. 인증 수정은 별도 fix PR에서 다루며, 적용 후 Repman의 실제 DB/ProxySQL 인증 및 역할 인식까지 확인해야 자동 복구 준비 완료라고 할 수 있다.

## 구축 내용

- 기존 Hikari·ProxySQL·MySQL 지표를 모은 Grafana UID: `stockspoon-db-fis`, Database 폴더.
- `db-fis.yml`: Semi-sync source/replica 상태 이름 정규화, 쓰기 가능 노드 수, Replica 기본 조건 recording rule. Semi-sync OFF/상태 누락·기본 복제 조건 미충족·Repman 인증 실패·로그 관측 불가 알림.
- Replica 기본 조건은 native lag=0, I/O·SQL thread ON, Semi-sync replica ON이다. Repman의 인증·후보 선출·fencing·failover 횟수 제한까지 입증하는 지표는 아니다.
- observer는 CloudWatch의 Repman 로그만 읽으며 DB 인증정보·승격 권한을 갖지 않는다. ProxySQL writer 변경은 기존 Prometheus 표본으로 관측한다.
- 원본 로그 이벤트 시각, CloudWatch 레코드 시각, observer 수집 시각을 구분한다. observer 최초 기동은 writer 변경 이벤트를 만들지 않는다.
- `repman_switch_complete`는 Repman의 전환 절차 완료다. 계획 전환도 같은 로그를 쓰므로 자동 failover 여부와 실제 SQL 성공을 별도 대조한다.
- `repman_node_failed`는 native Failed 상태 이벤트다. 해당 노드가 장애 직전 Primary였는지는 역할 증거와 대조한다.
- `proxysql_writer_observed`는 5초 scrape의 관측 시각이다. SQL commit 성공 시각이 아니다. 이전 표본 시각도 원장에 기록한다.
- state 로그가 없는 구간은 정상이라고 추정하지 않는다. observer 로그 조회는 성공했어도 Repman DB 인증이 정상이라는 뜻은 아니다.

## 두 복구 시각은 어디에 남기는가

1. **인프라 복구 증거:** Repman 원본은 CloudWatch `/ecs/stockspoon-v2-prod/repman`. observer가 구조화한 이벤트는 telemetry EBS `/srv/stockspoon-telemetry/db-fis/events.jsonl`과 Loki `{job="db-fis",environment="prod"}`에 남긴다. 로컬 원장은 10MiB 단위 최대 6개 파일로 회전한다. Loki 전송 실패 시 로컬 원장은 보존되지만 자동 재전송은 하지 않으며 마지막 전달 성공 여부를 별도 metric으로 노출한다. CloudWatch는 5분 겹침 조회와 event ID 중복 제거를 사용하므로 그보다 늦게 들어온 로그는 원본에서 별도 대조한다.
2. **실제 SQL 경로 복구:** ProxySQL을 경유한 전용 SQL probe가 트랜잭션 commit 성공과 시각을 DB 외부에 기록해야 한다. 이 PR은 SQL 쓰기 probe나 공유 DB 테이블을 만들지 않는다. writer ONLINE만으로 대체하지 않는다.
3. **고객 경로 복구:** 기존 `loadtest/fis-probe/db-path-rto.js`가 ALB→BE→ProxySQL→DB 조회 결과를 `run_id`, 요청 시작·완료 UTC 시각, 성공 여부, 응답 시간으로 JSONL에 기록한다. 토큰·응답 본문은 기록하지 않는다. 이 조회 probe는 쓰기 복구·RPO를 검증하지 않는다.

예시(기존 보호된 JWT 파일 사용, 실제 실행은 별도):

```sh
k6 run --env DB_FIS_RUN_ID=db-fis-<unique-id> \
  --env DB_FIS_PROBE_TOKEN_FILE=/secure/path/db-fis-probe.jwt \
  --log-format raw --console-output /secure/results/db-fis.api.jsonl \
  --out json=/secure/results/db-fis.metrics.json \
  loadtest/fis-probe/db-path-rto.js
```

실험별 외부 원장에 `run_id`, FIS experiment ID, 대상 EC2 ID/server UUID, 실제 장애 적용 시각(불명확하면 action-start 대리값임을 명시), 위 복구 이벤트를 연결한다. 고객 복구는 요청 성공과 합의된 지연 기준을 30초 연속 충족한 구간의 시작으로 정의할 수 있다. 판정 확정 시각은 30초 뒤다. 끊긴 probe·dropped iteration·인증 만료를 정상 복구로 간주하지 않는다. 인프라 전환 완료와 실제 SQL/API 복구를 구분하며 여기서 RTO 목표값을 임의로 정하지 않는다.

## FIS template에서 할 수 있는 범위

FIS `logConfiguration`으로 action-start/action-end 등 장애 주입 제어 이벤트를 CloudWatch Logs 또는 S3에 저장할 수 있다. 이 로그에 고객 API 복구 시각이 자동으로 생기지는 않는다.

```json
{
  "logConfiguration": {
    "logSchemaVersion": 2,
    "cloudWatchLogsConfiguration": {
      "logGroupArn": "<approved-FIS-log-group-ARN>"
    }
  }
}
```

`aws:ssm:send-command`를 사용해 DB와 분리된 probe 호스트의 사전 준비된 프로그램을 실행하도록 template에 연결할 수 있다. SSM 문서·실행 역할·대상·접속 경로는 별도로 필요하다. 동기식 send-command로 장시간 probe를 실행하면 장애 action 시작을 막을 수 있으므로 probe 시작/준비 완료→장애 주입→결과 회수의 실행 순서를 설계한다. DB 중단이 끝나도 독립 probe 관측은 복구 확인까지 유지해야 한다. Backend 코드 변경 없이 외부 probe로 두 경로의 복구를 측정할 수 있다. 이 PR은 FIS template을 생성하거나 장애를 실행하지 않는다.

공식 문서: [FIS 실험 로깅](https://docs.aws.amazon.com/fis/latest/userguide/monitoring-logging.html), [SSM 액션](https://docs.aws.amazon.com/fis/latest/userguide/actions-ssm-agent.html).

## RPO의 의미와 측정 계약

RPO(Recovery Point Objective)는 **조직이 정하는 허용 데이터 손실의 시간 목표**다. 장애 전 마지막으로 복구 가능한 데이터 지점부터 장애 발생까지의 허용 구간이다. 예를 들어 10:00:00 장애에 대해 09:59:55까지 완전하게 복구하면 관측 복구 지점의 간격은 5초다. 정상 운영 전체 길이나 손실 요청 건수를 RPO라고 부르지 않는다.

사용자에게서 접수한 쓰기는 접수 시각·내구성 확보 시점·DB commit·성공 응답을 구분해 DB 밖의 원장에 남긴다. 보호 범위는 업무 계약으로 정한다. 동기식 DB commit 성공을 확인한 요청과, HTTP 202로 내구성 큐 접수를 확인한 요청 모두 각각의 보존 계약에 따라 대사할 수 있다. 단순히 HTTP를 전송한 요청과 서버가 보존을 약속한 요청을 섞지 않고, 응답 유실로 commit 여부가 불분명한 요청도 별도 대사한다.

고유 ID 대사는 유실·불일치·중복 및 마지막 완전 복구 지점을 확인하는 방법이다. `|acknowledged − recovered|`는 유실 건수이며 RPO 정의 자체가 아니다. 장애 전 쓰기의 연속된 복구 지점을 UTC 시각과 함께 확인하고, 비연속 누락은 별도의 무결성 실패로 남긴다. 장애 중 실패한 신규 요청은 가용성 영향으로 보고하고, 접수·보존을 약속한 쓰기가 후속 유실되면 손실 대사에도 포함한다. 오래된 Primary 재편입이나 큐 재생으로 사후 보정하기 전 승격 DB의 복구 지점을 먼저 보존한다.

이 PR은 RPO 목표를 0으로 확정하거나 RPO 달성을 주장하지 않는다. Semi-sync timeout 10초도 RPO 상한이 아니다. [AWS recovery objectives 정의](https://docs.aws.amazon.com/wellarchitected/latest/framework/rel-availability-and-recovery-objectives.html).

## 배포와 검증

`monitoring/db_fis.tf`는 telemetry 역할에 해당 Repman 로그 그룹의 `logs:FilterLogEvents`만 추가한다. 관측기에는 DB/Repman API 자격 증명을 제공하지 않는다.

`python3 monitoring/scripts/deploy-db-fis.py prepare /tmp/db-fis-bundle`로 번들을 만든 뒤 telemetry 호스트에서 `python3 /tmp/db-fis-bundle/deploy.py apply --bundle /tmp/db-fis-bundle`로 적용한다. 기존 서비스 설정을 통째로 덮지 않고 신규 dashboard/rules/scrape job과 `compose.db-fis.yaml`을 설치한다. Prometheus는 promtool 검증 후 SIGHUP으로 재로드하며 Grafana는 기존 file provisioning으로 읽는다. 새 컨테이너만 시작하고 DB·Backend·ProxySQL·Repman은 재시작하지 않는다. 소스 bundle 변경 시 같은 명령으로 observer를 갱신한다.

관측기 Compose overlay는 기존 telemetry 프로젝트 이름을 사용한다. 전체 서버를 새로 만들면 위 관측기 설치도 별도로 수행해야 한다. live 원본 구성과 백업 경로는 배포 출력에 남긴다. 프로브가 아직 연결되지 않은 항목은 대시보드에서 미연결로 표시하며, RTO/RPO 0으로 채우지 않는다.

### 이번 작업의 실제 반영 결과

2026-11-28 KST에 telemetry 로그 읽기 IAM 정책 1개를 Terraform으로 추가하고, 관측기·신규 규칙·대시보드를 적용했다. Grafana UID `stockspoon-db-fis`의 25개 패널을 확인했으며 모든 Prometheus target 쿼리가 성공했다. 관측기 `up=1`, Repman/ProxySQL 수집 성공, Loki 이벤트 2건, 신규 recording/alert rule 9개 `health=ok`를 확인했다. Semi-sync source/replica STATUS=1, ACK 없는 commit 및 async 전환 counter=0이었다. Repman ErrorAuth 두 노드는 계속 관측되며 인증 수정은 별도 PR의 배포·검증이 필요하다.

Promtool config/rules 검사와 `db_fis.promql.yaml`의 정상 복제·역할 전환 후 지표 누락 사례가 통과했다. Python 모니터링 테스트 114개와 Terraform 오프라인 테스트 6개가 통과했다. Backend·DB·ProxySQL·Repman 재시작이나 FIS 장애 주입, 운영 API 부하 시험은 이 관측 배포에 포함하지 않았다.
