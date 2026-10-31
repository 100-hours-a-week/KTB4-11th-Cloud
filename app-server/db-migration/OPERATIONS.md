# apply 이후 접속·로그·MySQL 복제 준비

## 2026-10-15 확인한 상태

| 역할 | 인스턴스 ID | private IP | public IP | 확인 결과 |
| --- | --- | --- | --- | --- |
| V1 운영 | i-0b4b096567c84b58b | 10.0.1.246 | 15.164.87.85 | EC2 running; DB 내부 설정은 이번 점검에서 조회하지 않음 |
| 이관 DB | i-081a5f4798f592f49 | 10.0.1.217 | 3.36.92.128 | cloud-init 완료, MySQL 컨테이너 미실행 |
| 부하기 | i-0b766e6efa26389c9 | 10.0.1.116 | 13.209.83.189 | cloud-init 완료, k6 설치 |
| PMM | i-00dce75378431daf7 | 10.0.1.85 | 3.35.13.60 | cloud-init 완료, PMM healthy, 로그인 화면 HTTP 200 |

점검은 읽기 전용으로 수행했다. PMM에 등록된 서비스는 자체 PostgreSQL이며,
V1 MySQL과 이관 MySQL은 등록되지 않았다. 아래 설정·적재·복제 명령은 아직 실행하지 않았다.

## 1. PMM 화면과 접속

브라우저에서 <https://3.35.13.60:8443>에 접속한다.
자체 서명 인증서를 사용한다. 접근 허용 IP는 Terraform의 `db_migration_admin_cidrs`에 지정한 `/32`다.

PMM EC2에 AWS 콘솔의 EC2 → 인스턴스 → 연결 → Session Manager로 접속한다.
사용자명은 `admin`, 비밀번호는 이 호스트에서 다음 명령으로 확인한다.
비밀번호를 채팅이나 Git에 복사하지 않는다.

```bash
sudo cat /opt/stockspoon-pmm/admin-password
```

MySQL을 시작하고 등록한 뒤 다음 화면을 사용한다.

| 화면 | 확인할 항목 |
| --- | --- |
| Inventory | MySQL 서비스 및 수집 agent의 등록·실행 상태 |
| MySQL Instance Summary | QPS, 접속 수, 쿼리·InnoDB 관련 지표 |
| Query Analytics | 쿼리 유형별 실행 횟수와 소요 시간 |
| MySQL Replication Summary | replication 연결 이후 복제 스레드 및 지연 관련 지표 |

Query Analytics는 모든 원본 SQL·파라미터·성공 여부를 기록하는 감사 로그가 아니다.
ROW 복제로 들어온 변경은 원본 SQL의 재실행과 다르므로, 이관 DB의 QAN만으로
V1이 받은 원본 쿼리를 모두 확인할 수 없다. V1의 쿼리를 분석하려면 V1도 별도 등록해야 한다.
원격 DB 수집은 DB 호스트의 CPU·메모리·디스크 지표 수집까지 포함하지 않는다.

## 2. 로그 위치

### V1 운영 로그: CloudWatch

CloudWatch → Logs → Log groups에서 확인한다. 기존 Compose의 stdout/stderr 전송 경로다.

| 로그 | Log group | 코드에 설정한 보관 기간 |
| --- | --- | --- |
| MySQL 서버·오류 로그 | /stockspoon/app/containers/db | 7일 |
| 백엔드 | /stockspoon/app/containers/backend | 7일 |
| Nginx | /stockspoon/app/containers/nginx | 7일 |
| 시스템 | /stockspoon/app/system | 14일 |

현재 셸에 AWS CLI가 설치되어 있다면 다음과 같이 조회한다.

```bash
aws logs tail /stockspoon/app/containers/db --since 10m --follow --profile stockspoon --region ap-northeast-2
```

이 경로로 slow/general 로그 파일이 자동 전송되는 것은 아니다. MySQL 파일 로그는
별도로 파일 수집을 설정해야 CloudWatch에서도 확인할 수 있다.

### 새 실습 EC2: 호스트에서 확인

실습 EC2에는 CloudWatch Logs 전송을 설정하지 않았다. 해당 호스트의 SSM/SSH 세션에서 조회한다.
다음 `-f` 명령은 계속 실행되므로 종료할 때 Ctrl+C를 누른다.

```bash
# 각 실습 호스트: 설치·초기화 결과
sudo cloud-init status --long
sudo tail -n 100 /var/log/cloud-init-output.log
sudo journalctl -u cloud-final --no-pager -n 100

# PMM 호스트: PMM 컨테이너 출력
sudo docker logs --timestamps --tail 100 -f migration-pmm-server

# 이관 DB 호스트: MySQL을 시작한 이후 서버·오류 출력
sudo docker logs --timestamps --tail 100 -f migration-mysql
```

PMM/MySQL의 Docker 출력 로그는 파일당 20 MiB, 최대 3개로 순환한다.
Docker 출력 로그 설정이 MySQL slow/general 로그 파일의 용량까지 제한하지는 않는다.
부하기는 테스트 스크립트를 아직 배치하지 않았으므로 부하 테스트 결과 로그도 없다.

## 3. 이관 MySQL 시작과 PMM 등록

README의 파일 복사 및 실행 순서를 따른다. 스크립트에 전달할 실제 인자는 다음과 같다.

이관 DB 호스트에서 MySQL Compose 및 스크립트를 배치한 후:

```bash
sudo ç
```

PMM 호스트에서 최신 등록 스크립트를 배치한 후:

```bash
sudo bash /opt/stockspoon-pmm/configure_mysql.sh 10.0.1.217
```

등록 스크립트는 호스트에 저장한 PMM 관리자 비밀번호로 CLI를 인증한다.
내장 agent의 exporter는 `--metrics-mode=pull`을 사용한다. PMM Server 안에서 실행하는
exporter에 `push`를 지정하면 등록이 거절된다. 수집기와 PMM이 같은 컨테이너에 있으므로
이 변경을 위해 외부 exporter 포트를 추가로 열 필요는 없다.
비밀번호 변경 후 인증 옵션 없는 `pmm-admin list`는 Unauthorized를 반환할 수 있다.
2026-10-15 점검에서 관리자 인증을 명시한 목록 조회와 내장 agent 연결은 정상인 것을 확인했다.

### MySQL 첫 시작 직후 ERROR 1045가 발생한 경우

초기 버전 healthcheck는 `mysqladmin ping`을 사용했다. 이 명령은 인증 거절에도 성공을 반환하고,
초기화 중 임시 MySQL 서버에도 응답할 수 있어 root 비밀번호 설정 전에 다음 단계로 넘어갈 수 있다.
현재 코드는 실제 3306 TCP 연결에서 인증된 `SELECT 1`이 성공하도록 healthcheck와 대기를 수정했다.

이번 사례에서는 초기화 완료 후 기존 secret의 root 비밀번호로 접속되는 것을 확인했다.
이 경우에는 볼륨·비밀번호를 변경하지 않고 기존 설정 스크립트를 다시 실행해 남은 단계를 완료한다.
아래 명령은 Mac 터미널에서 실행한다.

```bash
ssh -i /Users/kimjihyeon/.ssh/stockspoon-v1-deploy ubuntu@3.36.92.128 \
  'sudo bash /opt/stockspoon-db-migration/scripts/configure_mysql.sh 10.0.1.217 10.0.1.85'
```

초기화가 완료된 뒤에도 인증 오류가 계속된다면 동일한 일시적 오류로 가정하지 말고,
비밀번호 파일과 기존 DB 볼륨의 초기화 이력을 확인한다. 이 절차에서 볼륨을 삭제하거나 비밀번호를 재생성하지 않는다.

## 4. MySQL 로그 설정

각 DB의 관리자 SQL 세션에서 먼저 현재 설정을 확인한다.
V1에서는 `sudo docker exec -it db mysql -uroot -p`로, 이관 DB 실행 이후에는
`sudo docker exec -it migration-mysql mysql -uroot -p`로 접속할 수 있다.
이관 DB root 비밀번호는 해당 호스트의
`/opt/stockspoon-db-migration/mysql/secrets/mysql-root-password`에 있다.

```sql
SHOW GLOBAL VARIABLES WHERE Variable_name IN (
  'log_error', 'log_output', 'slow_query_log', 'slow_query_log_file',
  'long_query_time', 'min_examined_row_limit', 'general_log', 'general_log_file',
  'log_bin', 'binlog_format', 'binlog_expire_logs_seconds', 'log_timestamps'
);
```

| 목적 | 사용 도구·로그 | 범위 |
| --- | --- | --- |
| 오류·시작·종료 확인 | Error log / Docker·CloudWatch 출력 | DB 서버 상태 |
| SQL 부하 분석 | PMM Performance Schema | 쿼리 유형별 집계 |
| 느린 SQL 원문 확인 | Slow query log | 지정한 기준을 넘긴 쿼리 |
| 접수 SQL을 짧은 실험 구간에서 추적 | General query log | 접수 기록; 커밋 성공·실행 순서의 증거와 다름 |
| 데이터 변경 복제 | Binary log | ROW 변경 이벤트; SELECT 기록용이 아님 |

다음은 관리자 SQL 세션에서 적용하는 예시다. 이번 점검에서는 실행하지 않았다.
원래 설정을 먼저 기록하고, 측정 목적과 디스크 여유에 맞춰 사용한다.

```sql
-- 200 ms는 실험 시작용 예시이며 서비스 SLO에서 결정한 값은 아니다.
SET GLOBAL log_output = 'FILE';
SET GLOBAL slow_query_log_file = '/var/lib/mysql/slow.log';
SET GLOBAL long_query_time = 0.2;
SET GLOBAL slow_query_log = ON;
```

`long_query_time` 변경은 새 세션의 기본값에 적용된다. 기존 백엔드 커넥션 풀의 세션 값은
계속 남을 수 있으므로 적용 시점을 구분한다. 시험이 끝나면 원래 값으로 복원한다.
GLOBAL 변경은 재시작 시 유지되지 않으므로, 상시 사용을 결정한 설정은 별도로 영속화한다.

새 이관 DB에서 slow 로그를 확인하는 예시:

```bash
sudo docker exec migration-mysql tail -n 100 -f /var/lib/mysql/slow.log
```

General log가 필요하면 짧은 관측 구간에만 다음처럼 사용한다.

```sql
-- 앞에서 log_output에 FILE이 포함된 것을 확인한 상태에서 사용한다.
SET GLOBAL general_log_file = '/var/lib/mysql/general.log';
SET GLOBAL general_log = ON;
-- 관측 종료 후 실행:
SET GLOBAL general_log = OFF;
```

General log는 쓰기 I/O와 디스크 사용량을 늘리며 SQL의 업무 데이터가 포함될 수 있다.
성능 기준 측정과 상세 SQL 추적의 실행 구간을 기록한다. General log를 영구 기본값으로 켜지 않는다.
ROW 복제 적용은 replica의 general/slow 로그에 원본 SQL로 그대로 남지 않는다.

## 5. MySQL Shell 초기 적재 전 확인

MySQL Shell의 dump/load는 특정 시점의 초기 데이터를 옮기는 작업이다.
그 이후 계속 발생하는 변경분은 MySQL의 binlog/GTID replication으로 전달한다.

V1 관리자 SQL 세션에서 다음 읽기 전용 결과를 먼저 확인한다.

```sql
SELECT VERSION(), @@server_id, @@server_uuid, @@log_bin,
       @@gtid_mode, @@enforce_gtid_consistency, @@binlog_format;
SELECT @@GLOBAL.gtid_executed, @@GLOBAL.gtid_purged;
SHOW BINARY LOGS;
SELECT TABLE_SCHEMA, ENGINE, COUNT(*) AS tables_count
FROM information_schema.tables
WHERE TABLE_TYPE = 'BASE TABLE'
  AND TABLE_SCHEMA NOT IN ('mysql','information_schema','performance_schema','sys')
GROUP BY TABLE_SCHEMA, ENGINE;
SELECT TABLE_SCHEMA,
       ROUND(SUM(DATA_LENGTH + INDEX_LENGTH) / 1024 / 1024, 1) AS estimated_mib
FROM information_schema.tables
WHERE TABLE_SCHEMA NOT IN ('mysql','information_schema','performance_schema','sys')
GROUP BY TABLE_SCHEMA;
```

다음 단계로 진행할 조건:

- Source binlog가 켜져 있고 필요한 기간의 변경분을 보관할 수 있어야 한다.
- Source GTID가 ON인지 확인한다. OFF이면 온라인 전환의 단계별 절차가 필요하며,
  OFF에서 ON으로 바로 바꾸는 명령을 실행하지 않는다.
- Source와 target의 server-id 및 UUID는 서로 달라야 한다.
- Dump 대상 전체 서비스 스키마와 InnoDB 사용 여부를 확인한다.
- 이관 호스트의 데이터·dump·binlog를 함께 보관할 디스크 여유를 확인한다.
- Source에 dump용 계정과 복제용 계정을 준비한다. PMM 계정을 재사용하지 않는다.
- Source의 binlog 보관 기간이 dump·load·복제 따라잡기 시간보다 충분히 길어야 한다.
- 이관 MySQL은 외부 업무 쓰기 없이 초기 적재 대상으로 유지한다.

V1 Compose에는 호스트 3306 publish가 없다. 따라서 `10.0.1.246:3306` 접근 경로부터 준비해야 한다.
기존 MySQL 서비스에 Compose `ports`를 추가해 적용하면 컨테이너 재생성이 발생할 수 있으므로,
운영 DB 재시작을 허용하지 않는 경우 별도 중계 또는 터널 방식으로 연결 경로를 설계한다.
이번 안내에서는 운영 컨테이너 재생성이나 중계 설치를 실행하지 않는다.

## 6. 초기 데이터 baseline

### Private replica 자동 baseline

현재 Terraform의 `db_private_replica_bootstrap`은 빈 Private replica에 Primary의 `stockspoon` 스키마를
`mysqldump --single-transaction --set-gtid-purged=ON`으로 스트리밍하고, 적재된 GTID 이력을 검증한 뒤
GTID auto-position 복제를 시작한다. 임시 seed 계정은 replica의 private IP와 TLS 연결로 제한하며,
복제가 정상화되면 Primary에서 제거한다. 중간 dump 파일은 만들지 않는다.

Primary에는 `stockspoon` 이외의 application schema가 없어야 하고 모든 기본 테이블이 InnoDB여야 한다.
적재 중에는 이 schema에 `ALTER TABLE`, `CREATE TABLE`, `DROP TABLE`, `RENAME TABLE`,
`TRUNCATE TABLE` 같은 DDL을 실행하지 않는다. dump 시작 시 GTID와 snapshot을 맞추기 위해
짧은 global read lock을 잡으며, 오래 실행 중인 쓰기 문장이 있으면 시작이 지연될 수 있다.
snapshot 이후 InnoDB DML은 계속 처리된다.
적재 후 검증은 Primary의 현재 `gtid_purged`가 replica의 `gtid_executed`에 포함되는지 확인한다.
따라서 Primary에 이미 purged된 이력이 있어도 baseline snapshot에 포함되면 복제를 시작할 수 있다.
다만 적재 중이나 복제가 따라잡기 전에 필요한 binlog가 추가 purge되면 bootstrap은 중단된다.
현재 binlog 보관 기간은 7일이므로 baseline 적재와 복제 catch-up을 그 안에 마쳐야 한다.

적재가 실패하면 helper는 부분 데이터나 GTID를 자동 삭제·초기화하지 않는다. 완료 marker가 없는
target은 재실행 시 overwrite를 거부하므로, 오류를 확인한 뒤 target을 복구하거나 새로 생성하고
baseline 절차를 다시 시작한다. 정상 완료 후에도 source·target GTID 집합과 replication thread를 확인한다.
초기 baseline 시작 전에는 application schema와 복제 채널이 없는 새 target에 한해, Docker 초기화에서
생긴 target 자체의 로컬 binlog/GTID 기록을 비운다. Primary의 binlog나 GTID 기록은 변경하지 않는다.

아래 MySQL Shell 절차는 기존의 수동 이관 실습용이다. Terraform이 관리하는 Private replica에
자동 baseline을 이미 적용했다면 동일 데이터를 다시 적재하지 않는다.

### MySQL Shell 수동 적재 예시

전제: 위 확인과 연결 경로·권한 준비를 완료한 상태다. MySQL Shell은 이관 EC2에서 실행하는
구성을 기준으로 한다. 설치되지 않았으므로 공식 8.4 LTS 배포물과 OS 지원 여부를 확인한 뒤 설치하고
`mysqlsh --version`으로 확인한다. 일반 `mysql` CLI와 다른 프로그램이다.

Source dump 계정에는 dump 대상의 SELECT·SHOW VIEW·TRIGGER·EVENT 권한,
일관된 snapshot을 위한 RELOAD/BACKUP_ADMIN 및 좌표 확인용 REPLICATION CLIENT 등을 준비하고
`dryRun`으로 부족한 권한을 확인한다.

```bash
mysqlsh --js --uri dump_user@10.0.1.246:3306 --password
```

MySQL Shell의 JS 모드에서 실행하는 예시:

```javascript
util.dumpInstance('/opt/stockspoon-db-migration/seed/v1-initial', {
  threads: 2,
  maxRate: '10M',
  consistent: true,
  users: false,
  dryRun: true
});
```

결과를 검토한 후 `dryRun: false`로 실제 dump를 실행한다. 2 threads와 thread당 10M 제한은
초기 실험용 예시이며 허용 부하를 실측해 조정한다. 성공한 dump의 `@.json`과 `@.done.json`을 보관한다.
계정 복사를 제외했으므로 앱 계정과 복제 계정은 별도 관리해야 한다.

`consistent:true`도 완전히 무락인 방식은 아니다. Snapshot을 맞추기 위한 초기 read lock이 있고,
백업 락은 DDL을 제한한다. 장기 실행 트랜잭션·쿼리와 락 대기 상태에 따라 영향이 달라질 수 있다.
정합성을 위해 `consistent:false`로 바꾸어 락을 피하지 않는다.

Target에는 MySQL Shell에서 접속 가능한 import 전용 관리자 계정을 별도 준비한다.
현재 Compose는 원격 root 접속을 열지 않았으며, CLI 호스트에서 실행하는 Shell이
`root@10.0.1.217`로 바로 접속할 수 있다고 가정하지 않는다.
계정 생성·권한 작업은 target 관리자 세션에서 binlog 기록을 끈 세션으로 수행하고,
import 전용 계정은 적재가 끝나면 폐기한다.

Target의 기존 GLOBAL 값을 기록한 뒤 import 동안만 변경한다.

```sql
SET GLOBAL super_read_only = OFF;
SET GLOBAL read_only = OFF;
SET GLOBAL local_infile = ON;
```

Target import 계정으로 연결한 Shell JS 세션에서 실행하는 예시:

```javascript
util.loadDump('/opt/stockspoon-db-migration/seed/v1-initial', {
  threads: 2,
  skipBinlog: true,
  updateGtidSet: 'append',
  showMetadata: true
});
```

`skipBinlog:true`는 적재 과정에서 target의 새로운 GTID가 생성되지 않게 한다.
`updateGtidSet:'append'`는 dump 시점의 source GTID를 target에 기록한다.
이미 source GTID가 겹치는 적재 완료 target에 이 명령을 처음부터 다시 적용하지 않는다.
적재 실패 시에는 오류와 진행 파일을 확인하고 복구한다. GTID 초기화 명령으로 우회하지 않는다.

적재 결과를 검증한 뒤 target의 `local_infile`은 원래 값으로 복원하고
`read_only=ON`, `super_read_only=ON`을 적용한다. 이후 replica SQL 스레드의 복제 적용은 허용된다.

## 7. GTID replication 연결과 확인

전제: source GTID ON, 원격 연결 가능, dump/load 성공, source의 필요한 binlog 유지,
복제 전용 계정 생성과 TLS 설정이 완료된 상태다. 아래는 target에서 실행하는 형태다.
비밀번호는 예시 문자열이며 실제 값을 Git이나 기록에 남기지 않는다.

```sql
CHANGE REPLICATION SOURCE TO
  SOURCE_HOST = '10.0.1.246',
  SOURCE_PORT = 3306,
  SOURCE_USER = 'repl_user',
  SOURCE_PASSWORD = '<replication-password>',
  SOURCE_AUTO_POSITION = 1,
  SOURCE_SSL = 1;
START REPLICA;
SHOW REPLICA STATUS\G
```

실습 예시는 암호화를 켜며, 운영 수준에서는 CA와 source 신원 검증 옵션까지 설정한다.
Source 복제 계정은 target에서 보이는 접속 IP로 제한하고 `REPLICATION SLAVE` 권한을 사용한다.

확인할 항목:

- `Replica_IO_Running=Yes`, `Replica_SQL_Running=Yes`
- `Last_IO_Error`, `Last_SQL_Error` 및 병렬 worker 오류
- `Seconds_Behind_Source` 값과 증가 추이; NULL을 지연 0으로 간주하지 않음
- Source에서 읽은 GTID와 target에서 실행한 GTID 진행

확정 시점의 source `@@GLOBAL.gtid_executed` 값을 별도로 기록하고, target에서 다음을 확인한다.

```sql
SELECT WAIT_FOR_EXECUTED_GTID_SET('<captured-source-gtid-set>', 30);
```

0이면 기록한 GTID 집합을 적용한 상태이고, 1이면 timeout이다.
이는 계속 갱신되는 source의 미래 트랜잭션까지 동기화됐다는 뜻은 아니다.
마지막 cutover 동기화는 쓰기 차단 후 확정한 GTID로 검사한다.

## 8. PLG로 쓰기 실패 관측

PMM의 Query Analytics는 쿼리 통계와 DB 상태를 보는 용도다. PLG는 백엔드 요청 로그와
MySQL 접수 SQL을 시간대별로 함께 검색하는 용도다. 현재 백엔드 로그는 요청 경로·상태·
requestId와 실패 이벤트를 남기지만, SQL 예외의 vendor error code나 SQL 원문을
백엔드 로그에 남기지는 않는다. 그래서 우선 API 실패 건수와 MySQL 접수 SQL을 비교할 수 있고,
요청 하나와 SQL 하나를 requestId로 직접 연결하지는 못한다.

PLG는 새 EC2를 만들지 않고 현재 PMM 호스트를 사용한다. 4 GiB 메모리에서 PMM과 PLG를
동시에 운영하지 않도록 설치 스크립트가 실행 중인 PMM 컨테이너를 중지한다. PMM 데이터
볼륨은 삭제하지 않는다. PLG가 준비되지 않으면 스크립트가 PLG 컨테이너를 내리고
설치 전 실행 중이던 PMM을 다시 시작한다.

### 8-1. Security Group 규칙 적용

Terraform 변경은 모니터링 호스트의 Loki `3100/tcp`를 V1·이관 DB에서만 받을 수 있게 하고,
Prometheus가 두 호스트의 node exporter `9100/tcp`를 조회하도록 한다. Grafana `3000/tcp`와
Prometheus `9090/tcp`는 외부에 공개하지 않는다. 변경 계획에서 EC2 변경·교체·삭제가 없는지
확인한 뒤 사용자가 apply한다.

```bash
AWS_PROFILE=stockspoon terraform -chdir=app-server plan -out=db-migration-plg.tfplan
terraform -chdir=app-server show -no-color db-migration-plg.tfplan
AWS_PROFILE=stockspoon terraform -chdir=app-server apply db-migration-plg.tfplan
```

### 8-2. 모니터링 호스트에 PLG 설치

로컬 저장소 루트에서 모니터링 호스트로 서버 구성을 복사한다.

```bash
scp -i "$REHEARSAL_KEY" -r app-server/db-migration/plg/server ubuntu@<모니터링-공인-IP>:/tmp/
```

모니터링 호스트에서 아래를 실행한다. 기본 private IP는 현재 확인된 V1 `10.0.1.246`,
이관 DB `10.0.1.217`이다. 설치 과정은 SSM에서 기존 `pmm` 계정 비밀번호를 읽어
mysqld exporter에 전달하며 비밀번호를 출력하지 않는다.

```bash
sudo bash /tmp/server/install.sh 10.0.1.246 10.0.1.217
sudo docker compose --env-file /opt/stockspoon-plg/.env \
  -f /opt/stockspoon-plg/compose.yaml ps
```

Grafana 관리자 비밀번호는 `/opt/stockspoon-plg/grafana-admin-password`에 root 전용으로
저장된다. 2026-10-26 이후 HTTPS를 활성화한 호스트는 `8-6`의 public IP URL로 접속한다.
아래 HTTP 터널은 HTTPS 활성화 전 초기 점검용이다. HTTPS 활성화 후에는 세션 쿠키가
Secure 속성을 사용하므로 브라우저 로그인에는 HTTPS URL을 사용한다.

```bash
ssh -i "$REHEARSAL_KEY" -N \
  -L 3000:127.0.0.1:3000 \
  -L 9090:127.0.0.1:9090 \
  ubuntu@<모니터링-공인-IP>
```

Grafana 계정은 `admin`이다. 기존 PMM을 다시 쓸 때는 PLG를 먼저 중지한 뒤 PMM을 시작한다.
`docker compose down`에는 `-v`를 붙이지 않아 PLG 보관 볼륨을 유지한다.

```bash
sudo docker compose --env-file /opt/stockspoon-plg/.env \
  -f /opt/stockspoon-plg/compose.yaml down
sudo docker start migration-pmm-server
```

### 8-3. V1·이관 DB 로그와 호스트 지표 연결

각 DB 호스트에 Alloy와 node exporter를 추가한다. 구성은 MySQL 데이터 볼륨을 자동 탐지해
읽기 전용으로 마운트하고, Docker 컨테이너 stdout/stderr와 `general.log`, `slow.log`를 수집한다.
Alloy의 Docker API 소켓 마운트는 호스트 Docker daemon에 대한 강한 권한을 준다.
실행 전에 `agent/compose.yaml`과 `agent/config.alloy`를 검토한다.

모니터링 호스트의 private IP는 Terraform output `db_migration_support_hosts`에서 확인한다.
로컬에서 두 DB 호스트에 각각 agent 구성을 복사한다.

```bash
scp -i "$REHEARSAL_KEY" -r app-server/db-migration/plg/agent ubuntu@<V1-공인-IP>:/tmp/
scp -i "$REHEARSAL_KEY" -r app-server/db-migration/plg/agent ubuntu@<이관DB-공인-IP>:/tmp/
```

각 호스트에서 실행한다. `<모니터링-private-IP>`는 위 output 값이다.

```bash
# V1 EC2
sudo bash /tmp/agent/install.sh v1 <모니터링-private-IP> db

# 이관 DB EC2
sudo bash /tmp/agent/install.sh migration-db <모니터링-private-IP> migration-mysql
```

### 8-4. 관측 시작과 Grafana 검색

MySQL `general.log`는 SQL 접수 내용을 남긴다. 부하 실험의 짧은 구간에만 V1 관리자 세션에서
`SET GLOBAL log_output='FILE'`, `SET GLOBAL general_log_file='/var/lib/mysql/general.log'`,
`SET GLOBAL general_log=ON`을 적용하고, 실험이 끝나면 `general_log=OFF`로 되돌린다.
원래 설정을 먼저 기록한다. 상세 단계와 로그 보안 주의사항은 이 문서의 `4. MySQL 로그 설정`을 따른다.

Grafana Explore에 자동 등록된 Loki 또는 Prometheus 데이터 소스를 선택하고 다음 쿼리를 쓴다.

```logql
{host="v1", job="docker", container="backend"} |= "event=http_request"
{host="v1", job="docker", container="backend"} |~ "event=http_request.*status=5[0-9]{2}"
{host="v1", job="mysql-general"} |~ "(INSERT|UPDATE|DELETE)"
sum(count_over_time({host="v1", job="mysql-general"} |~ "(?i)(INSERT|UPDATE|DELETE)" [1m]))
```

```promql
mysql_up{job=~"mysql-(v1|migration)",db_node!=""}
mysql_slave_status_seconds_behind_source or mysql_slave_status_seconds_behind_master
node_memory_MemAvailable_bytes
```

### ROW 바이너리 로그 이벤트를 Loki로 보내기

Alloy는 바이너리 로그 파일을 직접 읽지 않는다. 이관 EC2 호스트에 설치된 `mysqlbinlog`로 V1의
원격 이벤트를 텍스트로 해독하고, Alloy가 읽는 파일에 기록한다. 이 방법은 V1의 `log_bin=ON`,
`binlog_format=ROW` 설정을 사용하므로 MySQL 서버 설정을 추가로 바꾸지 않는다.

먼저 로컬에서 갱신된 agent 구성을 이관 EC2로 복사한다.

```bash
scp -i "$REHEARSAL_KEY" -r app-server/db-migration/plg/agent ubuntu@<이관DB-공인-IP>:/tmp/
```

이관 EC2에서 Alloy 구성을 갱신한다. 기존 Loki 주소를 `.env`에서 읽어 사용한다.

```bash
LOKI_PRIVATE_IP=$(sudo sed -n 's#^LOKI_PUSH_URL=http://\([^:]*\):3100/loki/api/v1/push$#\1#p' \
  /opt/stockspoon-plg-agent/.env)
test -n "$LOKI_PRIVATE_IP" && \
  sudo bash /tmp/agent/install.sh migration-db "$LOKI_PRIVATE_IP" migration-mysql
```

V1에서 `SHOW BINARY LOG STATUS\G`를 실행해 현재 `File`과 `Position`을 확인한다. 아래 명령의
`binlog.000007`과 `71292`는 예시이므로, 실행 시점의 결과로 바꾼다. 같은 `mysqlbinlog`가
포그라운드에서 실행 중이면 먼저 해당 터미널에서 Ctrl+C로 끝낸 뒤 실행한다.

```bash
sudo sh -c '
nohup mysqlbinlog \
  --defaults-extra-file=/etc/mysql/binlog-reader.cnf \
  --read-from-remote-server \
  --start-position=71292 \
  --stop-never \
  --connection-server-id=103 \
  --base64-output=DECODE-ROWS -vv \
  binlog.000007 \
  >> /opt/stockspoon-plg-agent/binlog-logs/binlog-decoded.log 2>&1 < /dev/null &
echo $! > /run/stockspoon-mysqlbinlog-reader.pid
'
```

이관 EC2의 Alloy가 파일을 Loki로 전송한다. Grafana Explore에서 Loki를 선택하고 조회한다.

```logql
{host="migration-db", job="mysql-binlog"}
{host="migration-db", job="mysql-binlog"} |~ "Write_rows|Update_rows|Delete_rows"
```

이 스트림은 자동으로 재시작 위치를 저장하지 않는다. 중지 후 다시 시작할 때는 V1의 최신 binlog
파일과 위치를 확인해 명령을 갱신한다. `binlog_row_image=FULL`인 경우 실제 행 값도 Loki에
들어가므로 접근 권한과 실험 종료 후 수집 프로세스 중지를 관리한다.

백엔드 로그는 API 경로별 상태와 `requestId`를 보여주고, MySQL general log는 DB에 도착한
SQL을 보여준다. Prometheus MySQL exporter는 V1과 이관 DB의 global status 및 복제 지표를
5초 간격으로 수집한다. V1은 기존 private 3306 중계 경로로 접근하며 같은 exporter의
다중 대상 `/probe` 기능을 사용한다. V1의 접수 SQL은 general log 파일에서 별도로 확인한다.

General log에 SQL 값이 포함될 수 있고 DB I/O와 로그 저장량도 늘어난다. Loki와 Prometheus는
72시간 보관으로 설정했다. 이 구성은 요청이 실패한 이유를 자동 판정하거나 실패한 쓰기를
재처리하지 않는 관측용 구성이다. 앱 로그와 SQL 로그는 시간대별 비교는 가능하지만,
현재 로그 형식만으로 API `requestId`와 MySQL 세션을 직접 연결하지는 못한다.
애플리케이션 밖에서 DB에 도착하지 않은 요청의 SQL 원문은 MySQL 로그에도 없다.

### 8-5. 양쪽 MySQL 지표 수집 — 2026-10-24 적용

현재 PLG 모니터링 호스트의 Prometheus에 다음 두 DB를 등록했다. `db_node`는 서버 식별자이며
switchover 이후에도 유지한다. 현재 쓰기 허용 여부는 `mysql_global_variables_read_only`로
확인한다. 기존 `db_role=migration-replica` label은 이전 쿼리 호환성을 위해 남겨 두었으며,
새 대시보드는 이 label을 역할 판단에 사용하지 않는다.

| 노드 | Prometheus job | 현재 역할 | 확인 결과 |
| --- | --- | --- | --- |
| V1, `10.0.1.246:3306` | `mysql-v1` | Primary | `mysql_up=1`, `read_only=0` |
| 이관 DB, `10.0.1.217:3306` | `mysql-migration` | Replica | `mysql_up=1`, `read_only=1`, I/O·SQL 스레드 1, native lag 0초 |

적용 전 replica exporter는 HTTP 수집 자체는 성공했지만 DB 인증이 거절되어 `mysql_up=0`이었다.
복제된 MySQL 계정이 Docker 네트워크에서만 접속하도록 제한되어 있어 모니터링 호스트의
`10.0.1.85` 접속을 허용하지 못했다. Primary에 기존 모니터링 계정과 같은 인증정보를 사용하는
`pmm@10.0.1.85` 계정을 만들고 정상 복제로 전달했다. 이 계정에는 TLS 연결, 최대 연결 3개,
`SELECT`, `PROCESS`, `REPLICATION CLIENT` 권한만 부여했다. 비밀번호와 인증 해시는 문서·로그에
기록하지 않는다. 새 replica를 다시 구축하면 이 계정과 접속 경로를 확인한다.

Grafana의 `Database` 폴더에 `MySQL · Primary & Replica` 대시보드를 추가했다.
경로는 `/d/stockspoon-mysql-replication`이다. 연결 상태, read-only, 연결·실행 스레드,
복제 I/O·SQL 스레드, native lag, 오류 번호, QPS, slow query 및 버퍼풀 지표를 표시한다.
복제 채널이 없는 Primary에서는 복제 패널에 해당 노드의 값이 없는 것이 정상이다.

대시보드는 `grafana/provisioning/dashboards/mysql.yaml`과 하위 JSON으로 재배포할 수 있다.
Grafana가 이미 실행 중이면 관리자 인증으로 `POST /api/admin/provisioning/dashboards/reload`를
호출해 새 provider를 반영한다. 비밀번호를 터미널 인자나 출력에 노출하지 않는다.
Prometheus는 `promtool check config` 검증 후 `POST /-/reload`로 반영했다. 적용 전 설정은
모니터링 호스트의 `/opt/stockspoon-plg/backups/mysql-monitoring-20261024T024111Z/`에 보관했다.

검증 시 양쪽 `mysql_up`의 2분 최솟값이 모두 1이었고, Grafana를 통한 12개 패널의
13개 쿼리가 모두 실제 데이터를 반환했다. 이 변경에는 heartbeat와 새 알림 규칙은 포함하지 않는다.

### 8-6. Grafana public IP HTTPS 접속 — 2026-10-26 적용

모니터링 EC2의 `https://3.35.13.60/d/stockspoon-mysql-replication`에서 기존 Grafana
계정으로 접속한다. 사용자명은 `admin`이며 비밀번호는 기존 파일을 유지했다. 새 Nginx
컨테이너가 외부 `443/tcp`의 TLS를 처리하고 내부 Grafana로 전달한다. Grafana `3000`과
Prometheus `9090`은 계속 호스트 loopback에만 연결한다.

EC2 보안그룹의 443 인바운드는 `db_migration_admin_cidrs`와
`db_migration_pmm_ssh_cidrs`에 있는 관리자 IPv4 `/32`만 허용한다. 외부 네트워크의 IP가
바뀌면 해당 관리 목록도 갱신해야 한다. 추가한 네 규칙은 Terraform state에 import했다.

Public IP를 SAN에 포함한 자체 서명 인증서를 사용하므로 브라우저에 인증서 경고가 표시된다.
인증서와 키는 `/opt/stockspoon-plg/https/tls/`에 있고, 개인 키는 root 및 프록시 그룹만
읽을 수 있다. 도메인과 공인 인증서를 도입하면 경고 없는 HTTPS로 전환할 수 있다.
공인 IP가 바뀌면 다음 명령으로 인증서와 Grafana 외부 URL을 갱신한다.

```bash
sudo bash /opt/stockspoon-plg/enable_grafana_https.sh <새-public-IPv4>
```

재배포용 소스는 `compose.https.yaml`, `https/nginx.conf`, `enable_grafana_https.sh`다.
`install.sh`는 `https/public.env`가 있으면 HTTPS Compose override도 함께 적용한다.
처음 활성화할 때는 이 세 파일을 서버의 `/opt/stockspoon-plg/`에 배치한 뒤 위 명령을 실행한다.
TLS 키와 인증서, 서버별 `public.env`는 Git에서 제외한다.

외부 HTTPS 로그인 페이지 200, 미인증 대시보드 API 401, 기존 계정 로그인 200 및
Secure·HttpOnly 세션 쿠키를 확인했다. 인증된 세션으로 DB 대시보드의 12개 패널을 조회했다.
프록시는 UID/GID 101, 읽기 전용 파일시스템, 권한 추가 금지 및 메모리 제한 64 MiB로 실행한다.
HTTPS 적용 전 설정 백업은 `/opt/stockspoon-plg/backups/grafana-https-20261025T232836Z/`에 있다.

2026-10-26 재점검에서 양쪽 DB 모두 24시간 표본이 각각 17,280개였으며
`min_over_time(mysql_up[24h])=1`이었다. 수집은 정상이며, Prometheus 및 Grafana의 새 알림
규칙과 heartbeat 지표는 아직 없었다. 현재 live scrape 목록에는 ProxySQL도 등록되어 있지 않다.

### 8-7. 시간 동기화 · heartbeat 복제 지연 · DB/ProxySQL 알림 — 2026-10-26 적용

**시간 동기화.** 모니터링 호스트는 시스템 시계가 동기화되지 않은 상태로 약 11.3초 늦었고,
이관 DB도 약 10일 전부터 동기화가 끊겨 있었다(V1 대비 약 50ms). Ubuntu 26.04 chrony는
Ubuntu NTS 서버를 인증 소스로 우선하는데, 두 호스트의 egress가 NTS를 허용하지 않아
비인증인 Amazon Time Sync(`169.254.169.123`)를 `W`(인증 소스 대기) 상태로 선택하지 않았다.
두 호스트에 `chrony/10-stockspoon-aws-time-sync.conf`(`authselectmode ignore`)를
`/etc/chrony/conf.d/`로 배치하고 chrony를 재시작했다. 모니터링 호스트는 재시작 시 시계가
앞으로 약 11초 step되어 Prometheus 표본에 약 11초 공백이 있다. 적용 후 세 호스트 모두
`169.254.169.123`을 기준으로 동기화되었고 모니터링 호스트와 DB 호스트 시계 차이는 약 10ms다.
V1은 NTS에 접근 가능해 변경하지 않았다. user_data 변경은 다음 apply에서 인스턴스 재시작을
유발할 수 있어 반영하지 않았으므로, 호스트를 새로 만들면 이 파일을 다시 배치한다.

```bash
sudo install -m 0644 10-stockspoon-aws-time-sync.conf /etc/chrony/conf.d/
sudo systemctl restart chrony
chronyc tracking   # Reference ID가 169.254.169.123, Leap status Normal
```

**Heartbeat.** switchover 스크립트는 애플리케이션 스키마가 `stockspoon` 하나이고 InnoDB 기본
테이블만 있어야 하므로, 별도 스키마 대신 `stockspoon.monitoring_heartbeat`
(pt-heartbeat 형식, InnoDB)를 V1 Primary에 만들고 복제로 전달했다. 기존 앱 테이블 16개는 변경하지 않았다.

| 항목 | 값 |
| --- | --- |
| writer | 모니터링 호스트의 `migration-heartbeat-v1`, `migration-heartbeat-migration` (`percona/percona-toolkit:3.7.2`, 1초 간격, `--utc`) |
| 계정 | `heartbeat@10.0.1.85`, `heartbeat@172.18.0.%`. TLS 필수, 최대 연결 2, 해당 테이블 `SELECT/INSERT/UPDATE/DELETE`와 `REPLICATION CLIENT`만 부여 |
| 비밀번호 | 모니터링 호스트 `/opt/stockspoon-plg/secrets/mysql-heartbeat-password` (root 전용) |
| 수집 | mysqld exporter `--collect.heartbeat*`, 기록 규칙 `mysql:heartbeat_lag_seconds` |

V1의 외부 3306 접속은 V1 호스트의 `v1-db-repl-proxy` 컨테이너(172.18.0.4)를 거쳐 들어오므로,
기존 `pmm@172.18.0.%`와 같이 V1 경로용 계정을 따로 두었다. 두 writer 모두 `--check-read-only`로
실행하므로 read-only 노드에는 쓰지 않는다. switchover 후에는 새 Primary 쪽 writer가 자동으로 기록한다.
heartbeat 계정에는 SUPER/CONNECTION_ADMIN이 없어 switchover가 `read_only=ON`으로 동결하는 순간
기록도 멈추므로, 동결 후 체크섬 비교에 영향을 주지 않는다.

지연 값은 대상 DB의 UTC 현재 시각에서 writer가 기록한 UTC 시각을 뺀 값이며, 가장 최근 행을 기준으로 한다.
writer 주기 때문에 정상 상태에서도 0~1초 값이 나온다. `ts`는 모니터링 호스트 시계로 기록되므로
위 시간 동기화가 이 측정의 전제다. 2026-10-26 적용 직후 측정값은 V1 1.0초, 이관 DB 0.8초였다.

**ProxySQL.** Cloud Map `proxysql-fargate.stockspoon-v2.internal`의 A 레코드를 `dns_sd_configs`로
수집해 Fargate task가 바뀌거나 늘어도 task별로 수집한다. 적용 시 대상은 `10.0.11.176:6070` 하나였고,
hostgroup 10(writer) V1, hostgroup 20(reader) 이관 DB 모두 ONLINE이었다.

**알림.** `prometheus-rules/db-alerts.yml`에 기록 규칙 1개와 알림 16개를 두었다. MySQL 수집 실패,
쓰기 가능 노드 수가 1이 아님, 복제 스레드 중지, read-only인데 복제 채널 없음, heartbeat 지연
10초/60초, Primary heartbeat 기록 중단, heartbeat 수집 실패, 연결 수 80% 초과, ProxySQL 수집
실패·대상 없음·writer ONLINE 없음·backend 비정상·풀 획득 실패, DB 호스트 시간 비동기화와
모니터링 호스트 시계 차이 1초 초과를 감시한다. 알림 전송은 8-8의 Alertmanager가 담당한다.

Grafana `MySQL · Primary & Replica` 대시보드에 `Heartbeat 복제 지연`, `ProxySQL (Fargate)` 행을
추가했다(총 21개 패널). 적용 시 `promtool check config`로 규칙 17개를 검증했고, 전체 패널 쿼리가 데이터를
반환했으며 발화 중인 알림은 없었다. 적용 전 설정은
`/opt/stockspoon-plg/backups/db-alerts-heartbeat-20261026T000023Z/`에 보관했다.

Mac에서 파일을 `tar`로 옮길 때는 `COPYFILE_DISABLE=1`을 지정한다. macOS 메타데이터 파일
`._*`가 `prometheus-rules/`에 들어가면 Prometheus 규칙 로드가 실패한다.

### 8-8. Discord 알림 전송 — 2026-10-26 적용

모니터링 호스트에 `migration-alertmanager`(`prom/alertmanager:v0.28.1`, loopback `9093`)를 추가하고
Prometheus `alerting` 대상으로 연결했다. 설정은 `alertmanager/alertmanager.yml`이다.

| 항목 | 값 |
| --- | --- |
| Webhook | SSM SecureString `/stockspoon/v1/db-migration/discord-webhook` (`alias/aws/ssm`, Standard) |
| 서버 파일 | `/opt/stockspoon-plg/alertmanager/secrets/discord-webhook`, `root:65534` `0440`, Git 제외 |
| 묶음 | `alertname`, `db_node`, `instance` 기준. 첫 전송 30초 대기, 같은 묶음 갱신 5분, 반복 4시간 |
| 해결 알림 | 전송 (`send_resolved: true`) |
| 억제 | `MySQLDown` 중 같은 노드의 warning, `MySQLHeartbeatLagCritical` 중 같은 노드의 `MySQLHeartbeatLagHigh` |

Webhook URL은 Terraform state에 남지 않도록 사람이 직접 SSM에 저장했다. 모니터링 호스트 역할에 붙은
`AmazonSSMManagedInstanceCore`가 `ssm:GetParameter`를 허용하므로 IAM 변경은 하지 않았다. 이 역할은 부하기
호스트와 공유한다. `install.sh`가 설치 시 파라미터를 읽어 파일을 만들며, 파라미터가 없으면 설치가 중단된다.
Webhook을 바꾸면 SSM 값을 갱신한 뒤 `install.sh`를 다시 실행하거나 파일을 갱신하고
`curl -XPOST http://127.0.0.1:9093/-/reload`를 호출한다.

```bash
read -rs DISCORD_WEBHOOK && aws ssm put-parameter --region ap-northeast-2 \
  --name /stockspoon/v1/db-migration/discord-webhook --type SecureString \
  --value "$DISCORD_WEBHOOK" --overwrite && unset DISCORD_WEBHOOK
```

적용 시 Alertmanager에 직접 넣은 `DiscordIntegrationTest` 알림이 Discord로 전송되었고
(`alertmanager_notifications_total{integration="discord"}=1`, 실패 0), 이후 해결 알림도 확인했다.
Prometheus 설정은 단일 파일 bind mount이므로 `prometheus.yml`을 교체(`mv`)한 뒤에는 `/-/reload`가 아니라
컨테이너를 다시 만들어야 새 파일이 보인다. 적용 전 설정은
`/opt/stockspoon-plg/backups/discord-alerts-20261026T003913Z/`에 보관했다.

## 9. Private GTID replica 및 ProxySQL 배포

현재 Public Primary는 유지하고, Terraform root `app-server`가 같은 AZ의 Private Subnet에 MySQL
replica EC2를 만든다. root user-data가 Docker MySQL과 SSM 관리 에이전트를 준비한다.
`app-server` root의 `terraform_data.db_private_replica_bootstrap`은 apply 중 SSM으로 GTID
복제를 설정한다. Private DB 운영 접속은 SSH inbound를 열지 않고 AWS Systems Manager Session
Manager를 사용한다. Private subnet의 SSM·패키지 설치 통신에는 기존 NAT 경로가 필요하다.

`db_private_replica_bootstrap`은 Private replica에 `stockspoon`의 일관된 InnoDB baseline을
Primary에서 직접 스트리밍한다. dump에는 source 시점의 GTID 집합이 기록되므로, 이전 적재에서
`gtid_purged`에 들어간 트랜잭션도 baseline에 포함되고, 이후 변경분은 `SOURCE_AUTO_POSITION=1`로
따라잡는다. Primary의 기존 데이터 변경이 과거 binlog에 남아 있어야 할 필요는 없다.

Source는 `stockspoon` 외 application schema가 없어야 하고 모든 기본 테이블이 InnoDB여야 한다.
baseline은 중간 파일 없이 MySQL 클라이언트 pipeline으로 전달된다. 복제본 시작 전 GTID 이력을
검증하고, Primary가 snapshot 이후 필요한 변경 binlog를 purge한 경우에는 복제를 시작하지 않는다.
현재 Primary binlog 보관 기간은 7일이며, 복제 IO/SQL thread가 정상으로 시작된 뒤 backlog는
비동기로 적용된다. 이 단계는 lag 0까지 기다리지 않는다.

새 복제본의 초기 GTID 이력이 있으면, application schema와 복제 채널이 없는 target에서만
target 자체의 초기화 GTID/binlog를 지운 뒤 baseline을 적재한다. Primary의 binlog·GTID 상태는
변경하지 않는다. baseline 중간 실패는 자동 초기화·덮어쓰기를 하지 않으므로 target 복구 후 재시도한다.

Primary에는 복제 대상 Private IP에만 한정된 TLS `db_private_replica` 계정과 임시
`db_private_seed` 계정을 준비한다. seed 계정은 baseline 적재 권한만 받고 정상 복제 확인 뒤 제거된다.
복제본은 계정 생성을 binlog에 기록하지 않고 로컬 ProxySQL monitor 계정을 준비한 뒤
`read_only=ON`, `super_read_only=ON`으로 운영하며 이 설정은 재시작 후에도 유지한다.

bootstrap이 복제 thread를 검증한 뒤 `ecs` root를 적용하면, Fargate ProxySQL이 현재 Public Primary를
writer hostgroup 10, Private replica를 read-only monitor 기반 reader hostgroup 20에 등록한다.
앱 계정의 기본 hostgroup은 10이므로 등록만으로 SELECT가 replica로 분산되지는 않는다. 읽기 분산은
앱의 트랜잭션·read-after-write 동작을 확인한 뒤 별도 query rule을 설계해야 한다. ProxySQL 서비스가
정상화된 다음 Terraform resource `aws_ec2_instance_state.retired_v1_app`가 기존 public V1 App
Server/replica EC2를 정상 정지한다. 현재 Primary는 계속 운영한다.

이 절차는 기존 GitHub Actions apply 역할에 SSM Run Command 권한을 추가한다. 저장소의
Terraform CI 정책 가이드대로 CI 역할은 자기 권한을 변경할 수 없으므로, 최초에는 AWS 관리자
자격으로 PR 브랜치에서 해당 정책만 먼저 Terraform state에 적용한 뒤 main CD를 실행한다.

`terraform -chdir=app-server apply -target='aws_iam_role_policy.github_actions_db_private_replica_bootstrap[0]'`

다음 Parameter Store SecureString은 Terraform state나 Git에 넣지 않고 사전에 관리한다.

| 파라미터 | 사용처 |
| --- | --- |
| `/stockspoon/v1/db-private-replica/root-password` | Private MySQL root 계정 |
| `/stockspoon/v1/db-private-replica/replication-password` | GTID replication 계정; 16–32자리 hexadecimal |
| `/stockspoon/v2/prod/backend/MYSQL_USER` 및 `MYSQL_PASSWORD` | ProxySQL Backend 계정 |
| `/stockspoon/v2/prod/backend/PROXYSQL_MONITOR_PASSWORD` | ProxySQL read-only monitor 계정 |

새 빈 Target의 최초 연결 시 Primary가 `read_only`/`super_read_only`, GTID, binlog, ROW-format 사전
조건을 만족하지 않거나 `gtid_purged`가 비어 있지 않으면 CD bootstrap이 중단된다. 이미 복제 중인
Target은 과거 GTID가 적용됐으므로 이후 binlog 만료와 `gtid_purged` 증가가 정상이며, 재적용 때 해당
검사를 반복하지 않는다. Target에 application schema/GTID history만 있고 정상 채널이 없거나 기존 채널의
상태가 비정상이면 자동으로 덮어쓰거나 GTID를 재설정하지 않는다. 이런 경우 원인을 확인하고 필요한
데이터 baseline 또는 수동 복구를 먼저 결정한다.

## 공식 문서

- [PMM MySQL 수집 지표](https://docs.percona.com/percona-monitoring-and-management/3/use/qan/mysql.html)
- [PMM CLI 인증과 설정](https://docs.percona.com/percona-monitoring-and-management/3/use/commands/pmm-admin/config.html)
- [MySQL Slow query log](https://dev.mysql.com/doc/refman/8.4/en/slow-query-log.html)
- [MySQL General query log](https://dev.mysql.com/doc/refman/8.4/en/query-log.html)
- [MySQL Shell Linux 설치](https://dev.mysql.com/doc/mysql-shell/8.4/en/mysql-shell-install-linux-quick.html)
- [MySQL Shell 8.4 LTS 다운로드](https://dev.mysql.com/downloads/shell/8.4.html)
- [MySQL Shell dump](https://dev.mysql.com/doc/mysql-shell/8.4/en/mysql-shell-utilities-dump-instance-schema.html)
- [MySQL Shell load와 GTID](https://dev.mysql.com/doc/mysql-shell/8.4/en/mysql-shell-utilities-load-dump.html)
- [온라인 GTID 활성화](https://dev.mysql.com/doc/refman/8.4/en/replication-mode-change-online-enable-gtids.html)
- [GTID 기반 복제 연결](https://dev.mysql.com/doc/refman/8.4/en/replication-gtids-howto.html)
- [GTID auto-position과 purged transaction](https://dev.mysql.com/doc/refman/8.4/en/replication-gtids-auto-positioning.html)
- [MySQL Shell loadDump의 GTID 업데이트](https://dev.mysql.com/doc/dev/mysqlsh-api-javascript/8.4/group__util.html)
- [GTID 대기 함수](https://dev.mysql.com/doc/refman/8.4/en/gtid-functions.html)
- [Grafana Alloy로 로그 수집](https://grafana.com/docs/alloy/latest/tutorials/logs-and-relabeling-basics/)
- [Alloy Docker 로그 수집기](https://grafana.com/docs/alloy/latest/reference/components/loki/loki.source.docker/)
- [Promtail에서 Alloy로 이전](https://grafana.com/docs/alloy/latest/set-up/migrate/from-promtail/)
- [Prometheus MySQL exporter](https://github.com/prometheus/mysqld_exporter)
