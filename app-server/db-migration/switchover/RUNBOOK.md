# DB 전환 · 캡처 · 리허설 후 복귀

이 폴더의 코드는 운영에 접속해 실행한 결과가 아니라, 현재 토폴로지용으로 작성한 실행 도구다. 자동 테스트는 실패 상황을 모사한다. 실제 MySQL/ProxySQL 통합 검증은 `check`와 리허설부터 수행한다.

| 구분 | V1 | 새 이관 DB |
| --- | --- | --- |
| 서버 주소 | `10.0.1.246:3306` | `10.0.1.217:3306` |
| server_id | `1` | `104` |
| server_uuid | `613cbc9f-ba4f-11f1-9bb7-1aa07765412a` | `68916670-cbad-11f1-a331-1ef0c86dbde0` |
| 처음 역할 | Primary | Standby, GTID auto-position |
| `switch` 완료 | Standby, 전환 지점부터 역복제 | Primary |
| `rollback` 완료 | Primary | Standby, 원래 GTID auto-position |

ProxySQL은 Fargate 서비스 `stockspoon-v2-prod-proxysql-fargate`, writer HG10 / reader HG20 / `read_only` 감지를 사용한다. 이 도구는 MySQL 역할·복제 전환과 ProxySQL writer 경로 검증만 수행하며, 기존 EC2 ProxySQL 삭제, ECS 배포, SSM JDBC 주소 변경은 수행하지 않는다.

## 이관 DB EC2에서 수동 실행

자동 실행이나 부팅 시 실행은 설정하지 않는다. 전환 담당자가 이관 DB EC2에 접속해 `check`, `capture`, `switch`, `rollback`을 명령으로 직접 시작한다. 이관 EC2에서는 V1과 이관 DB에 사설 주소로 직접 연결하고, Fargate ProxySQL의 Admin/App 포트만 ECS Exec 기반 SSM 터널로 연다. 보안그룹에 ProxySQL Admin 포트 6032를 추가로 개방하지 않는다.

이 실행 방식은 기존 `active query rules` 점검을 우회하지 않는다. 로컬과 EC2의 네트워크 경로는 다르지만, `Active query rules need a separate routing audit`는 ProxySQL Admin에서 조회한 규칙 수가 0이 아니면 어느 위치에서도 중단된다. 수동 조회와 스크립트 결과가 다르면 같은 Fargate task/Admin endpoint를 확인한다.

### Terraform 적용 전제

`app-server/db_migration.tf`는 전환 실행 전용 IAM role/profile을 만들고 DB 이관 EC2에 연결한다. 부하기 EC2와 PMM EC2는 기존 공용 profile을 유지한다. 전용 권한은 지정된 V2 ProxySQL Fargate 서비스/task 조회와 SSM 포트 전달만 허용한다. 이 IAM 변경을 Terraform으로 적용해야 실행할 수 있다. 기존 Fargate task role은 이미 `ssmmessages` 채널 권한과 ECS Exec 설정을 사용한다.

### 스크립트 복사 및 1회 준비

Mac의 저장소 루트에서 실행한다. `REHEARSAL_KEY`는 DB 이관 EC2 SSH 키 파일 경로이며, 키나 비밀번호를 저장소에 넣지 않는다.

```bash
export SWITCH_CODE="$PWD/app-server/db-migration/switchover"
export AWS_PROFILE=terraform-stella
export DB_MIGRATION_PUBLIC_IP="$(aws ec2 describe-instances \
  --region ap-northeast-2 \
  --instance-ids i-081a5f4798f592f49 \
  --query 'Reservations[0].Instances[0].PublicIpAddress' \
  --output text)"

scp -i "$REHEARSAL_KEY" -r "$SWITCH_CODE" \
  "ubuntu@$DB_MIGRATION_PUBLIC_IP:/home/ubuntu/switchover"
```

이관 DB EC2에서 실행한다.

```bash
sudo install -d -o ubuntu -g ubuntu -m 0750 /opt/stockspoon-db-migration/switchover
sudo cp -a /home/ubuntu/switchover/. /opt/stockspoon-db-migration/switchover/
sudo chown -R ubuntu:ubuntu /opt/stockspoon-db-migration/switchover
sudo bash /opt/stockspoon-db-migration/switchover/setup_runner_ec2.sh

export SWITCH_CODE=/opt/stockspoon-db-migration/switchover
export SWITCH_HOME="$HOME/.stockspoon-switchover"
mkdir -p "$SWITCH_HOME"
chmod 700 "$SWITCH_HOME"
cp "$SWITCH_CODE/config.ec2.example.json" "$SWITCH_HOME/config.json"
chmod 600 "$SWITCH_HOME/config.json"
```

`config.json`은 EC2가 직접 접속할 DB 주소 `10.0.1.246:3306`, `10.0.1.217:3306`과 로컬 ProxySQL 포트 `16032`, `16033`을 사용한다. `password_env`에는 비밀번호가 아니라 `SWITCH_*_PASSWORD` 이름이 들어간다. 값이 환경변수로 없으면 각 명령이 실행될 때 안전한 입력 프롬프트를 표시한다.

실행 전에 `target.uuid`, `target.server_id`, `target.server_host`, `target.server_port`가 **Fargate ProxySQL에 실제 등록되어 앱 트래픽을 받을 이관 DB**와 일치하는지 확인한다. 별도로 만든 임시 seed 컨테이너가 `127.0.0.1:3307`에만 바인딩되어 있다면 이 설정의 `10.0.1.217:3306`과 다른 DB다. 그 컨테이너를 전환 대상으로 쓰려면 ProxySQL 경로와 방화벽을 먼저 별도로 맞춘 뒤 config를 수정해야 한다. 스크립트의 UUID/server_id 점검은 다른 DB를 가리키면 중단한다.

### 명시한 단계만 매번 수동 실행

`check`, `capture`, `switch`, `rollback` 중 실행하려는 단계를 명령행 인자로 직접 지정한다. `run_ec2.sh`가 실행 중 Fargate ProxySQL Admin/App 포트의 SSM 터널을 열고, 해당 단계가 끝나면 터널을 닫는다. 시스템 부팅 시 자동 실행, 예약 실행, 단계 자동 진행은 설정하지 않는다. instance profile을 사용하므로 로컬 AWS 프로필을 지정하지 않는다.

```bash
export SWITCH_CODE=/opt/stockspoon-db-migration/switchover
export SWITCH_HOME="$HOME/.stockspoon-switchover"
unset AWS_PROFILE AWS_DEFAULT_PROFILE
```

읽기 전용 사전 점검:

```bash
bash "$SWITCH_CODE/run_ec2.sh" check --out "$SWITCH_HOME/check-ec2-01"
```

점검 결과가 통과된 뒤 각 단계를 따로 명시해 실행한다. `switch`와 `rollback`은 DB 역할을 변경하므로 실행 시점을 직접 결정한다. 출력 폴더는 매번 새 이름을 쓴다.

```bash
bash "$SWITCH_CODE/run_ec2.sh" capture --out "$SWITCH_HOME/capture-ec2-01"
bash "$SWITCH_CODE/run_ec2.sh" switch \
  --capture-dir "$SWITCH_HOME/capture-ec2-01" \
  --out "$SWITCH_HOME/switch-ec2-01"
bash "$SWITCH_CODE/run_ec2.sh" rollback \
  --switch-dir "$SWITCH_HOME/switch-ec2-01" \
  --out "$SWITCH_HOME/rollback-ec2-01"
```

DB 접속이 실패하면 `10.0.1.246:3306` 및 `10.0.1.217:3306`의 VPC 경로와 보안그룹부터 확인한다. ProxySQL task 교체나 터널 종료 시 helper가 터널을 닫고 전환 스크립트는 진행하지 않는다. `Active query rules need a separate routing audit`가 나오면 실행 위치로 우회하지 않는다. 같은 Fargate Admin 포트에서 활성 규칙이 0인지 다시 확인하고, 스크립트와 같은 ProxySQL 인스턴스에 연결되어 있는지 대조한다.

## 1. 실행 전 준비 — 한 번만

**로컬 Mac 터미널, 이 코드가 들어 있는 Cloud 저장소 루트**에서 실행한다. Python 3.9 이상, AWS CLI, Session Manager plugin, MySQL Shell 8.4의 `mysqlsh` 실행 파일이 필요하다.

```bash
export SWITCH_CODE="$PWD/app-server/db-migration/switchover"
export SWITCH_HOME="$HOME/.stockspoon-switchover"
mkdir -p "$SWITCH_HOME"
chmod 700 "$SWITCH_HOME"
python3 -m venv "$SWITCH_HOME/venv"
"$SWITCH_HOME/venv/bin/python" -m pip install -r "$SWITCH_CODE/requirements.txt"
cp "$SWITCH_CODE/config.example.json" "$SWITCH_HOME/config.json"
chmod 600 "$SWITCH_HOME/config.json"
command -v mysqlsh
```

설정 파일에는 비밀번호를 저장하지 않는다. 서버 UUID/ID가 실제와 다르면 `check`가 중단된다. 이전 `server_id=102` 컨테이너로 접속하도록 값을 바꾸지 말고, 포트가 새 seed 컨테이너를 향하는지 확인한다.

역복제용 계정은 **현재 Primary인 V1의 MySQL root 프롬프트**에서 준비한다. 아래 비밀번호를 직접 정한 값으로 바꾼다. 계정 생성은 정상 복제를 통해 이관 DB에도 전달된다. 기존 이름이 있다면 삭제하지 말고 먼저 권한과 용도를 확인한다.

```sql
CREATE USER 'switchover_reverse'@'10.0.1.246'
  IDENTIFIED BY '직접정한_역복제_비밀번호' REQUIRE SSL;
GRANT REPLICATION SLAVE ON *.* TO 'switchover_reverse'@'10.0.1.246';
```

**이관 DB root 프롬프트**에서 계정이 복제됐는지 확인한다.

```sql
SHOW GRANTS FOR 'switchover_reverse'@'10.0.1.246';
SHOW REPLICA STATUS\G
```

원래 순방향 계정은 `repl_seed_20261019`이다. `rollback`은 이 계정의 비밀번호를 다시 입력받는다. 역복제 접속은 V1 → 이관 DB의 TCP 3306을 사용한다. 코드의 `db_migration_mysql_from_app` 규칙이 이 경로를 허용하지만 실제 적용 여부는 확인해야 한다. MySQL에서 보이는 접속 출발 IP가 달라 계정 인증이 실패하면 스크립트는 승격 전에 중단한다.

다음 조건도 충족되어야 한다.

- 실제 실행 중인 BE와 쓰기 작업자가 Fargate ProxySQL을 사용한다. SSM 값 변경만으로 기존 프로세스의 연결은 바뀌지 않는다. V1에 직접 연결하는 백그라운드 작업은 전환 후 쓰기에 실패한다.
- 전환 중에는 DB/ProxySQL 컨테이너 재배포, DBA 쓰기, 스키마·계정 변경을 함께 실행하지 않는다. 이름 기반 MySQL lock은 다른 이 스크립트의 중복 실행만 방지한다.
- 양쪽 MySQL은 동일한 8.4 버전, GTID ON, `log_bin=ON`, `log_replica_updates=ON`, `sync_binlog=1`, `innodb_flush_log_at_trx_commit=1`, `persisted_globals_load=ON`이어야 한다.
- 현재 구현은 사용자 스키마 `stockspoon` 하나의 InnoDB 기본 테이블을 검증한다. 추가 스키마·뷰·트리거·루틴·DB 이벤트·복제 필터·다중 채널·Group Replication·준비된 XA가 있으면 중단한다.
- 앱 계정 `stockspoon`은 양쪽 DB에 존재하고 해당 스키마의 SELECT/INSERT/UPDATE/DELETE 직접 권한이 있어야 한다. 역할이나 테이블별 권한만 사용하는 구성은 별도 검증이 필요하다.
- 이관 DB의 현재 순방향 복제는 정상이어야 한다. 스크립트는 시작 시 양쪽 relay/applier 상태를 기록하고, 실제 역할 전환 중 양쪽 데이터 체크섬이 일치한 뒤 V1 receiver의 이전 applier 메타데이터를 초기화한다. `SHOW REPLICA STATUS`에 기존 수신 채널의 오류가 남아 있으면 사전 점검이 중단하므로 먼저 해당 상태를 확인한다. `relay_log`와 `relay_log_index`는 MySQL 시작 시 설정하는 변수이므로 `SET PERSIST_ONLY`로 바꾸지 않는다. Docker 재시작 후에도 relay log 이름을 고정해야 한다면 컨테이너의 시작 옵션에서 설정해야 하며, 이 스크립트는 컨테이너를 재생성하지 않는다.
- binlog는 리허설·복귀가 끝날 때까지 보존한다. `RESET BINARY LOGS AND GTIDS`, binlog 수동 삭제, 복제 오류 건너뛰기는 하지 않는다.

## 2. 접속 터널 열기 — 터미널 A

```bash
export AWS_PROFILE=terraform-stella
export AWS_REGION=ap-northeast-2
aws sts get-caller-identity
python3 "$SWITCH_CODE/tunnels.py" --config "$SWITCH_HOME/config.json"
```

`READY`가 나오면 이 터미널을 유지한다. V1 13306, 이관 DB 23306, 현재 Fargate ProxySQL Admin 16032, 앱 포트 16033을 로컬로 전달한다. 6032를 보안그룹에서 외부에 개방할 필요가 없다. Fargate 태스크가 하나로 안정화되지 않았거나 이미 로컬 포트를 쓰고 있으면 중단한다. 실행 중 태스크 변경이나 터널 종료도 감시한다.

AWS 로그인 만료라면 `terraform-stella`의 credential_process 원본인 `stella` 프로필에서 `aws login --profile stella` 후 다시 시도한다. 다른 CLI 프로필을 사용하는 팀원은 본인의 프로필을 지정한다.

## 3. 접속·토폴로지 점검 — 터미널 B

이 터미널에서도 `SWITCH_CODE`, `SWITCH_HOME`을 1번과 같이 설정한다.

```bash
"$SWITCH_HOME/venv/bin/python" "$SWITCH_CODE/switchover.py" check \
  --config "$SWITCH_HOME/config.json" --out "$SWITCH_HOME/check-01"
```

프롬프트에 순서대로 V1 root, 이관 DB root, ProxySQL Admin, BE의 `stockspoon` 비밀번호를 입력한다. 비밀번호는 화면·실행 인자·결과 JSON에 기록하지 않는다. 환경변수 `SWITCH_*_PASSWORD`로 제공할 수도 있지만, 공유 터미널에서는 입력 프롬프트를 권장한다. 결과 폴더는 덮어쓰지 않으므로 반복 실행할 때 `check-02`처럼 새 경로를 쓴다.

`check`는 영구 DB 설정을 변경하지 않는다. 연결·UUID·권한·현재 역할·복제 스레드·필터·ProxySQL 설정을 검사한다. 역복제 계정의 **실제 DB 간 접속**은 `switch` 중 양쪽을 잠근 뒤, 승격 전에 `START REPLICA`로 확인한다.

## 4. 데이터와 설정 캡처

```bash
"$SWITCH_HOME/venv/bin/python" "$SWITCH_CODE/switchover.py" capture \
  --config "$SWITCH_HOME/config.json" --out "$SWITCH_HOME/capture-01"
```

- `dump/`: MySQL Shell `util.dump_schemas(["stockspoon"], ..., consistent=True, checksum=True)` 결과. 운영 데이터가 들어 있으므로 접근권한을 유지한다.
- `dump.log`: 덤프 로그. GTID와 binlog 경계 메타데이터가 빠지거나 덤프가 미완료이면 성공 처리하지 않는다.
- `state.json`: DB UUID·역할·GTID·binlog 설정·양쪽 MySQL의 복제/relay 진단 자료·ProxySQL hostgroup 및 앱 계정 설정·persisted 역할 설정, 덤프 파일 SHA-256.

덤프는 일관된 스냅샷을 위해 짧은 읽기 잠금을 사용할 수 있다. 캡처 중 DDL을 배포하지 않는다. 설정 조회와 데이터 덤프는 서로 다른 시점이며, 데이터 시점은 덤프 메타데이터를 기준으로 한다. 이 백업에는 `mysql` 시스템 스키마·계정 비밀번호·EC2 볼륨 전체가 포함되지 않는다.

## 5. 실전 전환과 역복제 — 이 명령이 DB 역할을 변경한다

```bash
"$SWITCH_HOME/venv/bin/python" "$SWITCH_CODE/switchover.py" switch \
  --config "$SWITCH_HOME/config.json" \
  --capture-dir "$SWITCH_HOME/capture-01" --out "$SWITCH_HOME/switch-01"
```

앞의 네 비밀번호에 더해 `switchover_reverse` 비밀번호를 입력한다. 정상이라면 추가 질문 없이 아래 순서로 진행한다.

1. 양 DB에 실행 잠금을 얻고 신원·복제·ProxySQL 경로를 검사한다.
2. 이관 DB, V1 순서로 `SET PERSIST read_only=ON`, `super_read_only=ON`을 적용한다. 열려 있는 트랜잭션 때문에 잠금이 지연되면 시간 제한으로 중단한다.
3. V1의 마지막 GTID를 고정하고 이관 DB의 `WAIT_FOR_EXECUTED_GTID_SET` 반환값이 0인지 확인한다.
4. 이관 DB 복제를 멈추고 양쪽 테이블 구조, 정확한 행 수, `CHECKSUM TABLE ... EXTENDED`를 비교한다. GTID 적용 포함 관계와 V1의 최종 GTID 불변도 재확인한다.
5. 이관 DB의 binlog 파일·위치·GTID를 기록한다. 데이터 비교가 끝난 뒤 기존 복제 채널을 양쪽에서 `RESET REPLICA ALL`로 정리한다. 받은 GTID가 전부 적용됐는지 먼저 확인하며, 이 명령은 relay/applier 및 접속 메타데이터를 지우지만 사용자 데이터와 GTID 이력은 지우지 않는다. V1에서 새 채널을 만들고 파일·위치 경계부터 이관 DB를 따라가게 한 뒤, 채널 주소·계정·TLS·GTID 모드와 IO/SQL 스레드 정상 여부를 확인한다.
6. 이관 DB의 쓰기를 열고 ProxySQL HG10에 이관 DB만 남는지, 모니터가 새 역할을 확인했는지, 앱 계정으로 새 접속이 이관 DB UUID에 도착하는지 검사한다.
7. 승격 후 발생한 GTID를 V1이 적용했는지 확인하고 완료 기록을 남긴다.

**역복제 최초 시작은 file/position이다.** 이관 DB에만 있는 초기화·계정 GTID를 V1에서 다시 실행하지 않기 위해, 양쪽 앱 데이터가 같은 것을 확인한 정확한 경계부터 복제한다. 양 서버의 `gtid_mode`는 계속 ON이고 이후 트랜잭션은 원래 GTID로 전달된다. GTID를 인위적으로 추가하거나 오류를 건너뛰지 않는다. `mysql` 계정 구성이 완전히 같다는 뜻은 아니며 이후 계정 DDL은 양쪽 계정 상태를 고려해야 한다.

행 수와 체크섬은 전체 스캔이므로 쓰기 차단 시간을 늘린다. 현재 약 1MB/14개 테이블 규모에 맞춰 기본으로 수행한다. 체크섬은 충돌 가능성이 있는 검사이며 수학적인 데이터 동일성 증명은 아니다. DDL은 AUTO_INCREMENT 값까지 엄격히 비교하므로 차이가 나면 자동 수정하지 않고 중단한다.

`fence_request_to_route_ready_seconds`는 쓰기 잠금 요청부터 ProxySQL의 새 연결 확인까지 걸린 시간이다. 기존 BE 연결·진행 중 트랜잭션·HTTP 재시도까지 포함한 실제 사용자 다운타임은 별도 API 지표로 측정해야 한다. 스크립트 자체가 요청을 큐에 보관하거나 무유실을 보장하지 않는다.

## 6. 리허설 종료 후 원래 방향으로 복귀

부하 발생기와 별도 쓰기 작업을 멈춘 뒤 실행한다.

```bash
"$SWITCH_HOME/venv/bin/python" "$SWITCH_CODE/switchover.py" rollback \
  --config "$SWITCH_HOME/config.json" \
  --switch-dir "$SWITCH_HOME/switch-01" --out "$SWITCH_HOME/rollback-01"
```

순방향 `repl_seed_20261019` 비밀번호를 입력한다. 성공한 `switch` 기록과 같은 UUID일 때만 진행한다. 현재 Primary(이관 DB)의 쓰기 차단 → V1이 마지막 GTID까지 적용했는지 확인 → 양 DB의 테이블 정의·행 수·체크섬 비교 → 양쪽의 이전 채널과 relay/applier 메타데이터 정리 → V1을 Primary로 승격 → 이관 DB가 V1을 `SOURCE_AUTO_POSITION=1`로 복제하는지 검증 → ProxySQL 경로 확인 순서다. 원래 순방향 계정·접속 주소·재시도 설정을 사용한다. 중간 검증이나 새 채널 시작이 실패하면 둘 다 읽기 전용으로 남겨 운영자가 상태를 확인하게 한다.

이 명령은 **DB 역할과 복제 방향을 복귀**한다. 테스트 전 덤프를 다시 넣지 않으며 테스트 중 저장된 주문·계좌·인증 데이터를 삭제하지 않는다. GTID 이력, 단조 증가한 binlog 위치와 정지된 채널 메타데이터까지 과거 값으로 되돌리지 않는다. 테스트 데이터 삭제는 별도의 식별 기준과 정리 절차가 필요하다.

## 실패와 재시작 처리

모든 변경 요청 직전에 `state.json`을 디스크에 동기화한다. 시작 시 두 DB의 `SHOW REPLICA STATUS`, Performance Schema 복제 상태, applier 메타데이터, relay-log 변수, 최근 MySQL 복제 오류 로그를 기록한다. 복제 초기화/시작 단계가 실패해도 같은 진단 스냅샷을 실패 이벤트에 남긴다. `mysql.slave_master_info`는 복제 비밀번호가 들어 있으므로 수집하지 않는다. 프로세스 종료·타임아웃·불일치가 나면 자동으로 예전 Primary를 다시 열지 않는다.

- `preflight_ok` 이전 실패: 역할 변경을 시작하지 않았다.
- `fence_requested` 이후, `promotion_attempted` 이전 실패: 일부 또는 양쪽이 읽기 전용일 수 있다. `state.json`과 양쪽 실제 역할·복제 상태를 확인한다.
- `promotion_attempted` 이후 실패: 승격 SQL의 응답이 없어도 새 DB에 쓰기가 이미 들어갔을 수 있다. 이전 Primary의 쓰기를 즉시 열면 안 된다. 새 Primary 유지 상태에서 라우팅·역복제를 복구하고 새 쓰기 적용을 확인한다.

실패한 실행을 같은 인자로 자동 재개하거나 `rollback`으로 돌리지 않는다. `rollback`은 완료된 `switch`에만 사용한다. 기존 명령과의 호환을 위해 `restore`도 같은 동작의 별칭으로 남겨 둔다. 복구 판단에 필요한 조회는 각 DB의 root 프롬프트에서 수행한다.

```sql
SELECT @@server_uuid, @@server_id, @@read_only, @@super_read_only,
       @@global.gtid_executed, @@global.gtid_purged;
SHOW REPLICA STATUS\G
SHOW BINARY LOG STATUS\G
```

`SET PERSIST` 역할과 `SET PERSIST_ONLY` 복제 자동 시작·릴레이 로그 경로·복구 설정은 현재 데이터 볼륨에 저장한다. Primary는 복제 자동 시작을 막고 Standby는 복제 자동 시작을 허용한다. `mysqld-auto.cnf`나 볼륨을 지우지 말고, 역할에 맞게 Compose의 기본 옵션도 관리한다. 수동 설정 변경·다른 자동화·컨테이너 교체를 통제하는 전용 fencing 서비스까지 제공하는 도구는 아니다.

## 검증 및 근거

```bash
python3 -m unittest discover -s app-server/db-migration/switchover/tests -v
```

GTID 대기 시간 초과, 데이터 불일치, 역복제 인증 오류, 두 writer, 실행 잠금 상실, 승격 응답 유실, 승격 후 라우팅 실패, 원래 GTID 복제 복귀를 자동 테스트한다.

- [MySQL read_only / super_read_only](https://dev.mysql.com/doc/refman/8.4/en/server-system-variables.html#sysvar_super_read_only)
- [GTID 대기·집합 함수](https://dev.mysql.com/doc/refman/8.4/en/gtid-functions.html)
- [CHANGE REPLICATION SOURCE TO](https://dev.mysql.com/doc/refman/8.4/en/change-replication-source-to.html)
- [skip_replica_start와 PERSIST_ONLY](https://dev.mysql.com/doc/refman/8.4/en/replication-options-replica.html#sysvar_skip_replica_start)
- [CHECKSUM TABLE의 범위와 한계](https://dev.mysql.com/doc/refman/8.4/en/checksum-table.html)
- [AWS ECS 태스크 SSM 포트 전달](https://docs.aws.amazon.com/systems-manager/latest/userguide/session-manager-working-with-sessions-start.html)
