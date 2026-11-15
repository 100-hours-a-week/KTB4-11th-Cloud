# 데이터베이스 장애 주입(FIS)

이 Terraform root는 `app-server` state가 내보내는 `db_migration_host` EC2를 대상으로 수동 실행하는 AWS FIS 실험 템플릿을 만든다. 대상 EC2를 정상 종료 경로로 중지하고 2분 뒤 다시 시작한다. Terraform apply는 템플릿과 권한, 로그 그룹만 관리하며 실험을 자동으로 시작하지 않는다.

초기 DB 구성, Semi-sync·Repman 준비 순서, 실제 AWS 점검 결과는 [MySQL 장애 복구 초기 설정 가이드](INITIAL_SETUP.md)를 참고한다.

## 실험 대상과 관측 경로

- **장애 대상:** `db_migration_host` EC2 한 대다. ProxySQL Fargate task나 Backend task에는 장애를 주입하지 않는다. 템플릿은 Terraform state의 인스턴스 ID를 사용하므로 MySQL Primary 역할을 자동으로 찾아 바꾸지 않는다. 실행 직전에 해당 인스턴스가 현재 쓰기 Primary인지 확인한다.
- **서비스 RTO:** 실제 서비스 복구 시간을 보려면 기존 synthetic probe를 ALB → ECS Backend → ProxySQL → MySQL 경로로 보낸다. ALB의 정상 분산을 유지해 사용자가 경험하는 서비스 경로를 측정한다. 특정 Backend task를 고정하는 검사는 task 단위 진단용으로 분리하며, ALB를 거친 서비스 RTO와 섞어 해석하지 않는다. Backend 서비스의 task 수나 autoscaling 최대값을 1로 줄일 필요는 없다. ECS FIS target을 Backend service로 제한하고 `COUNT(1)`을 설정하면 현재 대상 중 하나를 무작위 선택한다. 특정 task만 시험해야 한다면 task ARN을 고정한다.
- **DB 경로 관측:** ProxySQL을 통해 별도의 읽기 검사 또는 중복 실행에 안전한 쓰기 검사를 수행하면 DB와 ProxySQL 경로를 좁혀 볼 수 있다. 이 검사는 ALB와 Backend를 포함한 서비스 RTO를 대신하지 않는다.
- **RPO:** 클라이언트가 성공 응답을 받은 트랜잭션의 고유 마커를 외부에 기록하고, 복구된 DB에 남은 마커와 비교한다. GTID 위치와 복제 지연은 진단 정보이며, 단독으로 관측된 RPO를 뜻하지 않는다.

정의한 작업 성공 조건이 다시 충족되는 시점까지가 RTO다. FIS는 장애 주입·실험 이벤트 기록을 담당하고, RTO 숫자는 요청을 실제로 보내 성공 여부와 시각을 남기는 probe에서 계산한다. 2분은 FIS가 EC2를 다시 시작하기 전의 주입 시간일 뿐 RTO 목표가 아니다. PLG 지표와 로그는 타임라인 분석에 함께 사용한다.

## Backend를 통과하지 않는 SQL probe

DB/ProxySQL 경로만 보려면 Backend 애플리케이션 대신 VPC 안의 별도 probe task에서 ProxySQL의 Cloud Map DNS와 client port `6033`으로 MySQL 프로토콜 접속을 한다. 이 요청은 Backend를 거치지 않지만 ProxySQL과 MySQL은 거친다. 개인 노트북에서 바로 실행하는 방식이 아니라, VPC DNS를 해석하고 ProxySQL `6033`에 접근할 수 있는 진단 task/호스트가 필요하다.

현재 `ecs/cross_root_rules.tf`는 ProxySQL `6033` 인바운드를 Backend와 선택적 collector SG에만 허용하고 PMM에는 metrics port `6070`만 연다. 전용 probe를 쓰려면 probe SG에서 ProxySQL `6033`으로만 접근하도록 제한된 SG 규칙을 준비한다. 기존 switchover 터널 helper는 ECS Exec로 ProxySQL에 연결하지만, ECS task FIS 작업 중에는 ECS Exec를 비활성화해야 하므로 그 터널을 fault-injection probe로 전제하지 않는다.

기본 연결·라우팅 점검 쿼리:

```sql
SELECT @@server_uuid AS server_uuid,
       @@read_only AS read_only,
       UTC_TIMESTAMP(6) AS database_time;
```

이 쿼리는 DB 응답과 연결된 MySQL 노드를 확인한다. ProxySQL query rule이 `SELECT`를 reader hostgroup으로 보내는 구성이라면 writer 정상 여부는 증명하지 않는다. 쓰기 failover와 RPO를 측정하려면 사전에 승인된 전용 probe table을 준비하고, 각 요청에 유일한 `run_id`와 증가하는 `seq`를 넣는다. 테스트 중에는 DDL을 실행하지 않는다.

```sql
INSERT INTO stockspoon.fis_probe_marker (run_id, seq)
VALUES ('<실험 UUID>', 1);
```

probe 프로그램은 각 시도 시각과 응답 성공 여부를 DB 밖에 기록한다. 성공 응답을 받은 마커만 acknowledged set으로 간주하고, 복구 뒤 테이블에 남은 마커와 비교해 유실된 acknowledged write를 RPO로 계산한다. `SELECT 1` 또는 `SELECT @@server_uuid`만 반복하면 연결 복구는 볼 수 있지만 RPO는 계산할 수 없다.

## 실행 전 점검

실험 템플릿은 고정된 EC2 ID를 대상으로 한다. Primary/Standby 역할 전환이 있었다면 Terraform state의 `db_migration_host`가 여전히 현재 Primary를 가리키는지 확인한다. 역할과 대상이 다르면 실험하지 않는다.

1. 대상 EC2 ID, MySQL `server_uuid`, `read_only=0`, `super_read_only=0`을 확인해 현재 쓰기 Primary와 일치하는지 검증한다.
2. Standby EC2가 실행 중인지 확인하고 MySQL I/O 및 SQL 복제 thread, 적용된 GTID 위치, heartbeat 지연을 점검한다. 실험의 RPO 사전 조건도 정한다.
3. ProxySQL writer hostgroup 10이 해당 Primary를 가리키며 writer가 정상 상태인지 확인한다. ALB를 통과하는 Backend 쓰기 probe도 실험 직전에 성공시킨다.
4. Terraform에서 가져온 Backend 가용성 및 오류 중단 알람이 `OK`인지 확인한다. 오류 알람은 분당 요청이 20건 이상일 때 평가되므로, 안전한 probe 부하로 알람이 실제 작동하는지 확인한다. 배포를 멈추고 복구 담당자를 대기시킨다.
5. 정상 상태의 지표·로그·probe 결과를 기록하고, 성공 응답을 받은 트랜잭션 마커를 외부에 저장한다. FIS 이벤트는 CloudWatch Logs에 기록된다.

Standby가 없거나 복제 상태 또는 ProxySQL writer 경로가 검증되지 않았다면 이 실험을 failover/RTO/RPO 시험으로 해석하지 않는다. 그런 상태에서 실행하면 DB failover 능력이 아니라 Primary 중지 후 호스트 재기동만 관측하게 된다.

## 자동 failover를 시험하기 전에 준비할 항목

### 현재 준비 상태 (2026-11-16, AWS 조회 전용 점검)

- Primary `i-081a5f4798f592f49`와 Replica `i-09246a4ca3a6724e5`는 모두 실행 중이고 같은 AZ(`ap-northeast-2a`)다. MySQL server ID, 읽기 전용 값, GTID 상태, Semi-sync 플러그인과 복제 thread를 SSM 조회로 확인했다.
- Primary의 Semi-sync source 상태와 Replica의 Semi-sync replica 상태는 모두 `ON`이다. Primary 설정은 timeout 10초, Replica ACK 1개, `AFTER_SYNC`이며 MySQL `SET PERSIST`로 영속화돼 있다. 10초 내 ACK가 없으면 비동기 복제로 돌아갈 수 있으므로 RPO 0 보장으로 해석하지 않는다.
- 두 DB에 `replication_manager_schema`, `repman`, `repman_repl`이 준비돼 있음을 확인했다. 필요한 비밀 값은 SSM `SecureString`에 있으며 조회 과정에서 비밀 값은 열람하지 않았다.
- ECS Terraform에는 Repman Fargate service와 ProxySQL 연동 설정이 준비돼 있지만 **실제 apply는 아직 하지 않았다.** 현재 ECS에 Repman service는 없고 ProxySQL service는 기존 task definition revision `6`으로 desired/running 각각 1개다. 따라서 Repman 자동 승격과 새 ProxySQL 설정은 아직 실행 중이 아니다.
- Repman Terraform은 DB와 다른 AZ의 private subnet을 요구한다. 현재 DB는 `2a`에 있고 VPC에 private subnet `2c`가 있으므로 배치 후보는 존재한다. DB 두 대가 같은 AZ이므로 DB AZ 장애는 복구 범위에 포함되지 않는다.
- 현재 `api-https-bind=true` 설정만으로 Repman API의 TLS가 활성화되지는 않는다. 인증서를 연결하기 전 API 인증정보를 사용하지 않도록 [초기 설정 가이드](INITIAL_SETUP.md)의 보안 유의사항을 먼저 확인한다.

저장소에는 운영자가 명시적으로 실행하는 계획 전환 및 복귀 코드가 있다: `app-server/db-migration/switchover/switchover.py`와 `app-server/db-migration/switchover/RUNBOOK.md`의 `check`, `capture`, `switch`, `rollback`. 이것은 양쪽 DB에 접속해 Primary 쓰기를 막고 복제 적용·데이터를 확인한 뒤 전환하는 **계획된 switchover** 절차다. RUNBOOK도 실제 MySQL/ProxySQL 통합 검증을 마친 결과가 아니며 `check`와 리허설부터 하도록 명시한다. Primary가 갑자기 사라졌을 때의 장애 감지·후보 선출·승격·ProxySQL 갱신·구 Primary 재편입을 자동 수행하는 crash failover 절차는 아직 없다.

이 실험의 목표는 수동 복구 시간이 아니라 **자동 승격 RTO/RPO**다. Signal18 Replication Manager(repman)를 후보로 두고, 자동 failover를 활성화한 리허설에서 감지·승격·ProxySQL 라우팅·구 Primary 재편입까지 검증한다. FIS는 Primary 장애를 만들고 Repman이 자동 복구하는지 시험한다. Repman 공식 문서의 기본 설정은 수동 모드이므로 `failover-mode="automatic"`을 명시해야 한다.

### 우선 조정할 옵션

아래는 옵션 영향도를 비교할 시작점이며, 바로 운영값으로 고정할 설정이 아니다.

| 실험 축 | 시작 설정/비교 | 관측할 효과 |
|---|---|---|
| 자동 승격 | `failover-mode="automatic"` | Primary 장애 확인 후 사람 승인 없이 승격하는지 |
| 후보 지연 허용 | `failover-max-slave-delay=30`과 `0` 비교 | 허용 지연을 줄이면 RPO 위험은 낮아지지만 승격 가능한 후보가 없어질 수 있음 |
| 복제 동기화 조건 | `failover-at-sync=false`와 `true` 비교 | `true`는 Semi-sync SYNC 상태인 Replica를 요구한다. 상태가 조건을 충족하지 않으면 가용성보다 데이터 안전성을 우선해 승격을 보류할 수 있음 |
| 반복 장애 제한 | `failover-limit=3`, `failover-time-limit=10`부터 평가 | 연속 장애나 네트워크 flap에서 승격 반복을 제한하는 효과 |
| 오탐 방지 | DB reachability 재확인, 복제 heartbeat, 독립 arbitrator/witness | 네트워크 단절을 Primary 사망으로 오판해 split-brain을 만드는지 |
| ProxySQL 연동 | writer HG10 / reader HG20, ProxySQL Admin 6032 연결 | 기존 query rule·계정 설정을 보존하면서 backend 역할만 갱신하는지 |
| 구 Primary 복귀 | rejoin/autorejoin 방식 및 데이터 복구 조건 | 재기동한 구 Primary가 새 Primary의 Replica가 되고 writable로 남지 않는지 |

현재 DB는 2노드이고 같은 AZ다. Repman task를 다른 AZ의 private subnet에 배치하는 계획은 준비했지만 아직 배포하지 않았다. Repman이 다른 AZ에 있어도 두 DB가 같은 AZ에 있는 상태는 AZ 장애 복구를 제공하지 않는다. 2노드만으로는 네트워크 분할 때 어느 쪽이 Primary인지 독립 다수결을 만들 수 없으므로, Repman의 arbitrator/witness 및 기존 Primary fencing 방식을 설계에 넣는다. Repman의 arbitration 기능별 제3자 서비스·구독 조건도 배포 전에 확인한다.

Repman의 직접 ProxySQL 연동은 ProxySQL Admin `6032` 접근이 필요하다. 현재 live ProxySQL은 `mysql_ifaces="127.0.0.1:6032"`로 loopback에만 바인딩한다. 작업 중인 Terraform 변경은 새 task revision에서 6032를 task interface에 노출하고 Repman 전용 SG에서만 접근하게 하며 관리자 인증정보를 SSM SecureString으로 가져오도록 한다. 이 변경은 아직 적용하지 않았다. Repman은 hostgroup 10/20의 backend 역할을 관리하고, task 재시작 시 Terraform bootstrap이 DB의 현재 `read_only` 역할을 다시 확인해 writer/reader를 복원하도록 준비했다.

현재 live ProxySQL task의 bootstrap은 원래 Primary/Replica IP를 고정 writer/reader로 사용한다. 작업 중인 Terraform 변경은 새 task 시작 시 두 DB의 `read_only`를 조회해 현재 writable node를 writer HG10에 두고, health check도 특정 IP 대신 writer hostgroup의 ONLINE backend 수를 확인한다. Repman의 ProxySQL bootstrap은 backend hostgroup 관리만 켜고 users/query rules/variables 변경은 끄도록 준비했다. 이 방식은 Terraform이 task 시작 때 DB 역할을 복원하고 Repman이 실행 중 역할 전환을 반영하도록 설계했다. 실제 승격과 task 재시작에서 각각 검증해야 하며, 현재 변경은 ECS에 배포되지 않았다.

현재 복제는 GTID auto-position과 Semi-sync를 사용한다. Repman 설정은 `failover-at-sync=true`로 준비돼 있어 Semi-sync가 마지막 상태에서 SYNC가 아닐 때 승격을 보류할 수 있다. `false`로 바꾸면 복구 가능성은 높아질 수 있지만 async fallback 동안 acknowledged write가 Standby에 없을 위험을 감수하게 된다. 설정 비교에서는 실제 응답 성공 마커를 외부에 기록해 RPO를 실측한다. Semi-sync ACK는 Replica 수신을 확인하는 것이며 timeout 뒤 async fallback도 가능하므로 이를 단독으로 RPO 0 보장으로 해석하지 않는다. GTID 자체도 RPO 0을 보장하지 않는다.

자동 failover는 다음 순서로 검증한다: Repman이 두 MySQL과 ProxySQL을 정확히 감지하는지 확인 → 계획 전환으로 ProxySQL hostgroup 갱신과 구 Primary 재편입 검증 → 독립 SQL probe 및 ALB probe 준비 → FIS로 현재 Primary 호스트 장애 주입 → 자동 승격, ProxySQL writer 갱신, API/SQL 성공 시각과 acknowledged marker 손실 측정. 설정별 비교는 동일한 주입 조건과 부하로 반복한다.

현재 FIS template은 Terraform `db_migration_host`의 **고정 EC2 ID**를 대상으로 한다. 계획 전환 스크립트가 MySQL 역할만 바꾸면 Terraform EC2 ID는 그대로다. Repman이 승격한 다음 실험은 실제 Primary ID를 확인할 수 있도록 target을 명시적으로 입력하거나 검증된 role-tag 갱신 경로를 구현해야 한다. Terraform state만으로 MySQL의 실시간 Primary 역할을 판별하지 않는다.

실험 종류도 분리한다: Backend task 하나의 장애는 ECS/ALB 복원력 시험, ProxySQL task에서 Primary 방향 TCP 3306 차단은 ProxySQL 경로 시험, Primary DB 호스트 장애는 DB 승격·라우팅 복구 시험이다. 한 실험에서 한 장애만 주입하고 그에 맞는 probe와 복구 절차를 사용한다.

## 실험 범위와 한계

`aws:ec2:stop-instances`는 기본값인 정상 OS 종료를 사용하고, 설정한 시간이 지나면 EC2를 다시 시작한다. 강제 전원 차단, `mysqld` 프로세스만의 종료, AZ 장애를 재현하지 않으며 Standby 승격이나 ProxySQL writer 전환도 수행하지 않는다. 따라서 현재 FIS 템플릿만으로는 Primary 호스트 정지·재기동을 관측할 뿐 자동 failover RTO를 측정하지 않는다. 승격 절차를 갖추기 전에는 이 Primary 중지 실험도 시작하지 않는다.

Primary와 Standby가 같은 AZ에 배치되어 있으므로 이 실험은 AZ 장애 대응 능력을 검증하지 않는다. 중단 조건은 기존 Backend 가용성 및 오류 CloudWatch 알람을 사용한다.

ProxySQL task에서 `aws:ecs:task-network-blackhole-port`로 egress TCP 3306을 차단하는 것은 Primary 하나만 차단하는 실험이 아니다. Primary와 Standby가 모두 3306을 사용하므로 ProxySQL의 모든 DB backend 연결을 막는다. 이는 ProxySQL 전체 DB 연결 단절 시험으로 분리한다. ECS task FIS 작업에는 task 정의의 fault injection 활성화, `pidMode=task`, SSM agent sidecar의 정상 등록이 필요하다. ProxySQL task 정의에는 설정이 있지만, 2026-11-14 live 확인에서는 sidecar가 종료 상태(exit code 137)였다. 해당 네트워크 실험 전에 sidecar를 복구·검증해야 한다.

Backend task를 직접 대상으로 하는 FIS 실험은 현재 Terraform 그대로는 준비되지 않았다. `ecs/svc_backend.tf`의 Backend task definition에는 `pid_mode=task`, `enable_fault_injection=true`, SSM agent sidecar가 없다. Backend task 하나를 FIS로 고르는 방식은 가능하지만, 먼저 이 task definition과 필요한 IAM·sidecar 구성을 추가해야 한다. Fargate 네트워크 장애 액션은 `useEcsFaultInjectionEndpoints=true`도 지정한다. ECS Exec가 켜져 있으면 해당 ECS task 액션과 함께 사용할 수 없으므로 비활성 상태도 확인한다.
