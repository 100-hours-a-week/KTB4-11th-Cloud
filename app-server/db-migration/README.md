# V1 MySQL 이관 실습 인프라

V1 운영 EC2와 같은 VPC 및 Public Subnet에 다음 세 호스트를 구성한다.
이관 DB EC2는 이미 생성되어 있으며, 이번 계획은 이를 유지하고 부하기와 PMM을 추가한다.

| 역할 | EC2 유형 | 메모리 | 암호화 gp3 | 준비하는 프로그램 |
| --- | --- | --- | --- | --- |
| 이관 DB | t3a.medium | 4 GiB | 40 GiB | Docker, Compose; MySQL은 아래 별도 설정 단계에서 실행 |
| API 부하기 | t3a.small | 2 GiB | 20 GiB | Docker, Compose, k6 |
| PMM Server | t3a.medium | 4 GiB | 60 GiB | Docker, Compose, PMM Server 3.9.1 |

2026-10-15 기준 이관 DB는 `i-081a5f4798f592f49`, private IP `10.0.1.217`이다.
부하기와 PMM의 apply는 사용자가 직접 실행한다. 계획 검증은 완료했으며,
신규 두 호스트의 생성과 서비스 동작 검증은 아직 수행하지 않았다.
초기 데이터 적재, GTID replication 연결, 실제 부하 발생, Primary 교체는 별도 단계다.

## PMM Server와 Client

- PMM Server: 수집 결과를 저장하고 웹 대시보드와 Query Analytics를 제공한다.
- PMM Client: MySQL 지표와 쿼리 통계, 설치된 호스트의 시스템 지표를 수집한다.
  별도 EC2가 필요한 프로그램은 아니며, 관측할 DB 호스트에 설치할 수 있다.
- 이 구성은 PMM Server 내장 agent가 이관 MySQL에 원격 접속하는 방식이다.
  이관 DB의 SQL 통계와 복제 지표를 수집하지만, 원격 DB 호스트의 CPU·메모리·디스크를
  온전히 수집하려면 해당 호스트의 Client 또는 별도 시스템 exporter가 필요하다.
- 현재 V1에는 PMM Client 설치나 DB 등록을 수행하지 않는다. V1 MySQL의 private
  포트 공개와 모니터링 계정도 아직 준비되지 않았다.

Query Analytics는 쿼리 유형별 실행 횟수·시간 등 통계를 보여준다.
모든 원본 SQL과 파라미터, 실행 순서, 커밋 결과를 빠짐없이 보관하는 감사 로그로 사용하지 않는다.

PMM은 메모리 절약용 ClickHouse 설정, 메트릭 보관 72시간, 컨테이너 메모리 한도
3200 MiB로 구성했다. 4 GiB 호스트에서 실행하는 실습용 설정이며, 부하에 따른 메모리
사용량과 OOM 여부는 실행 후 확인해야 한다. 데이터는 Docker named volume의 `/srv`에 저장한다.

## 사용자가 직접 apply

저장소 루트에서 실행한다. 기존 `app-server` 원격 state를 함께 사용하므로,
계획에서 V1 EC2와 기존 이관 DB EC2의 변경·교체·삭제가 없는지 확인한다.
검증 당시 결과는 **26개 추가, 1개 수정, 0개 삭제**이며 EC2 추가는 두 대다.
기존 이관 DB의 outbound 전체 허용은 HTTPS 443으로 줄이고 필요한 별도 규칙을 추가한다.

```bash
terraform -chdir=app-server show -no-color db-migration-three-hosts.tfplan
AWS_PROFILE=stockspoon terraform -chdir=app-server apply db-migration-three-hosts.tfplan
AWS_PROFILE=stockspoon terraform -chdir=app-server output db_migration_host
AWS_PROFILE=stockspoon terraform -chdir=app-server output db_migration_support_hosts
AWS_PROFILE=stockspoon terraform -chdir=app-server output -raw db_migration_pmm_url
```

저장된 계획 이후 코드나 원격 state가 바뀌었다면 계획을 다시 만들고 검토한다.
다른 접속 IP를 사용한다면 `db_migration_admin_cidrs`를 수정한 뒤 다시 계획한다.
현재 기본 관리자 IP는 `211.244.225.224/32`다.

```bash
AWS_PROFILE=stockspoon terraform -chdir=app-server init -lockfile=readonly
terraform -chdir=app-server fmt -check
AWS_PROFILE=stockspoon terraform -chdir=app-server validate
AWS_PROFILE=stockspoon terraform -chdir=app-server plan -out=db-migration-three-hosts.tfplan
```

이 파일들은 아직 커밋되지 않았다. apply 후 같은 state를 사용하는 이전 코드에서
plan/apply하면 해당 코드에 없는 실습 리소스가 삭제 대상으로 잡힐 수 있다.
실습 중에는 다른 브랜치 및 자동화의 `app-server` apply와 조율한다.

## 접속과 초기화 확인

각 실습 호스트에 SSM 접속 역할을 사용하며, SSH는 관리자 `/32`만 허용한다.
SSH 사용자명은 `ubuntu`, 키 페어는 기존 `stockspoon-v1-deploy`다.
SSM은 AWS 콘솔의 Session Manager로 접속할 수 있다. 다음 CLI 명령에는 로컬
Session Manager plugin이 필요하다.

```bash
aws ssm start-session --profile stockspoon --region ap-northeast-2 --target <instance-id>
```

각 호스트에서 초기화를 확인한다. Terraform apply 성공만으로 user data 완료를 판단하지 않는다.

```bash
sudo cloud-init status --wait
sudo cat /opt/stockspoon-db-migration/bootstrap-complete
sudo docker compose version
```

부하기에서는 `k6 version`을 확인한다. 부하는 자동 실행되지 않는다.
PMM 호스트에서는 다음을 확인하고, output의 `https://<public-ip>:8443`로 접속한다.
사용자명은 `admin`이며 비밀번호는 해당 호스트의 root 전용 파일에 저장된다.
기본 자체 서명 인증서를 사용한다.

```bash
sudo docker ps --filter name=migration-pmm-server
sudo cat /opt/stockspoon-pmm/admin-password
```

새 Elastic IP를 만들지 않으므로 실습 EC2를 중지 후 시작하면 공인 IP가 바뀔 수 있다.

## 필요한 연결

| 시작 | 목적지 | TCP 포트 | 용도 |
| --- | --- | --- | --- |
| 관리자 `/32` | 실습 EC2 세 대 | 22 | SSH |
| 관리자 `/32` | PMM | 8443 | 웹 UI |
| 부하기 | V1 | 80, 443 | API 호출 |
| V1 ↔ 이관 DB | 각 MySQL | 3306 | 복제 및 전환 후 DB 연결 준비 |
| PMM | V1, 이관 DB | 3306 | MySQL 원격 수집 |
| V1, 이관 DB, 부하기 | PMM | 8443 | Client 연결 준비 |
| 실습 EC2 | 외부 | 80, 443 | 패키지·이미지 다운로드, SSM 등 |

MySQL 3306은 허용된 Security Group 사이에서만 연다. 부하기의 DB 직접 접속은 허용하지 않는다.
기존 V1의 공개 웹 규칙은 유지하며, 표는 실습에 필요한 연결을 나타낸다.
현재 V1 Compose에는 MySQL 호스트 포트 publish가 없다. 따라서 SG 규칙만으로 V1 DB에
접속할 수 없으며 복제 단계에서 private IP publish와 binlog·GTID·계정 설정을 준비해야 한다.

## 이관 DB 시작 및 PMM 등록: apply 이후 수동 실행

아래 작업은 기존 V1이 아닌 새 이관 DB와 PMM 호스트에서만 수행한다.
SSH/scp 예시의 `<...>`를 Terraform output과 실제 키 파일 경로로 치환한다.
SSM으로 파일을 배치해도 동일하다.

로컬에서 이관 DB 호스트로 두 파일을 복사한다.

```bash
scp -i <key.pem> app-server/db-migration/mysql-compose.yaml app-server/db-migration/configure_mysql.sh ubuntu@<db-public-ip>:/tmp/
```

이관 DB 호스트에서 실행한다. 첫 인자는 이관 DB private IP, 둘째 인자는 PMM private IP다.
MySQL 8.4.11은 V1 로그에서 확인한 버전에 맞췄다. 비어 있는 DB를 시작하고 GTID·binlog·
Performance Schema를 켜며, 최종적으로 `super_read_only=ON`으로 설정한다.
PMM 전용 계정은 PMM private IP만 허용하고 TLS를 요구한다.

```bash
sudo install -d -m 0700 /opt/stockspoon-db-migration/mysql /opt/stockspoon-db-migration/scripts
sudo install -m 0600 /tmp/mysql-compose.yaml /opt/stockspoon-db-migration/mysql/docker-compose.yaml
sudo install -m 0700 /tmp/configure_mysql.sh /opt/stockspoon-db-migration/scripts/configure_mysql.sh
sudo bash /opt/stockspoon-db-migration/scripts/configure_mysql.sh <db-private-ip> <pmm-private-ip>
```

MySQL root 및 PMM 계정 비밀번호는 이관 DB의 `mysql/secrets/`에 root 전용 파일로 생성된다.
모니터링 계정 비밀번호만 SSM SecureString
`/stockspoon/v1/db-migration/mysql-monitoring`에 저장한다. Terraform은 비밀번호를 생성하거나
state에 기록하지 않는다. 이 SSM 파라미터는 실습 종료 시 별도 삭제 대상이다.

로컬에서 PMM 호스트로 등록 스크립트를 복사한다.

```bash
scp -i <key.pem> app-server/db-migration/configure_pmm_mysql.sh ubuntu@<pmm-public-ip>:/tmp/
```

PMM 호스트에서 실행한다. SSM에서 모니터링 계정 비밀번호를 읽어 내장 agent에
`migration-target` MySQL을 등록하고 상태를 출력한다.

```bash
sudo install -m 0700 /tmp/configure_pmm_mysql.sh /opt/stockspoon-pmm/configure_mysql.sh
sudo bash /opt/stockspoon-pmm/configure_mysql.sh <db-private-ip>
```

등록 후 PMM UI에서 MySQL 지표와 Query Analytics 수집을 확인한다.
복제 지표는 실제 replication을 연결한 이후 확인할 수 있다.
이 단계는 seed나 V1 DB 설정, V1 PMM 등록을 수행하지 않는다.

## 실험 순서와 기록

1. 현재 설정과 데이터·디스크 크기, 버전, CPU credit, 테스트 계좌를 기록한다.
2. EBS 크기 확장과 파일시스템 확장을 진행하면서 API 성공률·지연을 기록한다.
3. 컨테이너 CPU·메모리 한도와 MySQL buffer pool 변경을 각각 측정한다.
4. MySQL Shell로 초기 데이터를 적재하고 GTID replication을 연결한다.
5. 별도 부하기에서 API 부하를 주며 replica 상태와 GTID 진행을 기록한다.
6. 쓰기 정지, 마지막 GTID, target 적용 완료, DB 연결 전환, API 정상화 시각을 기록한다.

다운타임은 HTTP 접수 성공만으로 판단하지 않는다. 주문 DB 반영 여부까지 확인하고,
첫 실패부터 마지막 실패까지의 시간, 전체 실패 수, 응답 지연, 성공한 요청의
중복·누락을 함께 기록한다. Replica lag는 `Seconds_Behind_Source`와 복제 스레드
상태·오류를 함께 기록하며, 마지막 동기화는 GTID 실행 집합으로 확인한다.

EBS Elastic Volumes는 지원되는 인스턴스에서 실행 중 확장할 수 있지만,
볼륨 변경 후 파일시스템 확장도 필요하다. Docker의 실행 중 자원 한도 변경은
`docker update`로 시험한다. Compose 설정만 바꾸어 재배포하면 컨테이너 재생성이
발생할 수 있다. EC2 자체 인스턴스 유형 변경은 중지가 필요하다.

V1의 전체 메모리는 4 GiB이며 기존 Compose의 명시적 메모리 한도 합계는 약
3.1 GiB다. MySQL 한도를 올리기 전에 호스트의 실제 여유 메모리를 확인한다.
루트 EBS는 EC2 삭제 시 함께 삭제되므로 필요한 dump와 결과는 외부에 보관한다.

## 측정 도구의 역할

k6는 API 요청 수·성공률·응답 시간을, PMM은 DB 쿼리 통계와 복제 상태를 측정한다.
기존 CloudWatch는 애플리케이션 및 컨테이너 로그 확인에 사용한다.
수 초의 전환 구간은 별도 1초 단위 DB 상태 표본과 요청별 시각으로 확인한다.
PMM 대시보드의 수집 간격만으로 짧은 쓰기 차단 시간을 정확히 확정하지 않는다.

## 이후 큐 설계의 범위

외부 주문 API는 앞단 접수 경로에서 SQS FIFO에 저장하고 Lambda가 기존 API를
호출하도록 설계할 수 있다. 이때 응답은 실제 주문 완료와 구분해야 한다.
백엔드 내부 시세 이벤트와 만료 스케줄러의 DB 쓰기는 이 외부 API 경로를
통과하지 않으므로 Lambda가 자동으로 보관할 수 없다.

SQS FIFO 순서는 `MessageGroupId` 안에서 보장된다. 계좌 단위 순서를 원하면
계좌별 group을, 전체 순서를 원하면 하나의 group을 사용한다. DB 전환 중에는
소비를 멈추고 정상 쓰기 가능과 백엔드 연결 복구까지 확인한 뒤 재개한다.

SQS/Lambda는 재처리될 수 있다. Lambda에서 기존 주문 API를 호출해 DB가
커밋했는데 응답이 유실되면 Lambda만으로 주문의 중복 생성까지 보장하기 어렵다.
현재 API의 중복 방지 기능을 확인하고, 부족하면 업무 계층의 중복 방지를
추가해야 한다. 큐 설계는 측정 결과와 이 제약을 확인한 뒤 진행한다.

## 참고 문서

- [EBS Elastic Volumes](https://docs.aws.amazon.com/ebs/latest/userguide/ebs-modify-volume.html)
- [Docker container update](https://docs.docker.com/reference/cli/docker/container/update/)
- [EC2 인스턴스 유형 변경](https://docs.aws.amazon.com/AWSEC2/latest/UserGuide/change-instance-type-of-ebs-backed-instance.html)
- [MySQL buffer pool resize](https://dev.mysql.com/doc/refman/8.4/en/innodb-buffer-pool-resize.html)
- [PMM 3 시스템 요구 사항](https://docs.percona.com/percona-monitoring-and-management/3/install-pmm/plan-pmm-installation/hardware_and_system.html)
- [PMM Server와 Client 구조](https://docs.percona.com/percona-monitoring-and-management/3/reference/index.html)
- [PMM MySQL 연결](https://docs.percona.com/percona-monitoring-and-management/3/install-pmm/install-pmm-client/connect-database/mysql/mysql.html)
- [SQS FIFO 순서](https://docs.aws.amazon.com/AWSSimpleQueueService/latest/SQSDeveloperGuide/FIFO-queues-understanding-logic.html)
- [Lambda SQS 재처리](https://docs.aws.amazon.com/lambda/latest/dg/with-sqs.html)
