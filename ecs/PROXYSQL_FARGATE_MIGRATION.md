# ProxySQL EC2 → Fargate 단계 전환

기존 `stockspoon-v2-prod-proxysql` 서비스를 계속 실행한 채, 동일한 설정으로 `stockspoon-v2-prod-proxysql-fargate`를 추가합니다. DB 계정·복제·데이터는 바꾸지 않습니다. 로그는 기존 CloudWatch 그룹 `/ecs/stockspoon-v2-prod/proxysql`을 공유합니다. Backend JDBC 주소는 Terraform 코드에서 Fargate endpoint로 고정되어 있습니다. 기존 ProxySQL은 별도 정리 전까지 계속 실행합니다.

## 1. Fargate ProxySQL만 추가

루트 디렉터리에서 실행합니다. 기존 로컬 변수 파일이 있으면 평소처럼 `-var-file=...`도 두 명령에 지정합니다.

```bash
terraform -chdir=ecs plan \
  -target='aws_ecs_service.proxysql_fargate[0]' \
  -out=/tmp/proxysql-fargate-create.tfplan

terraform -chdir=ecs show -no-color /tmp/proxysql-fargate-create.tfplan
```

계획에 Fargate 서비스, Fargate Task Definition, Fargate용 Cloud Map 이름 생성만 있는지 확인합니다. 기존 ProxySQL, Backend, Frontend, DB, SSM 주소, 기존 CloudWatch 로그 그룹의 변경이나 삭제가 하나라도 보이면 적용하지 않습니다. 확인한 계획만 적용합니다.

```bash
terraform -chdir=ecs apply /tmp/proxysql-fargate-create.tfplan
```

기존 서비스와 새 서비스는 서로 다른 DNS 이름을 사용합니다.

```text
기존: proxysql.stockspoon-v2.internal:6033
신규: proxysql-fargate.stockspoon-v2.internal:6033
```

출력과 ECS 상태를 확인합니다.

```bash
terraform -chdir=ecs output proxysql_fargate
aws ecs describe-services --region ap-northeast-2 \
  --cluster stockspoon-v2-prod-cluster \
  --services stockspoon-v2-prod-proxysql-fargate \
  --query 'services[0].{status:status,running:runningCount,desired:desiredCount,events:events[0:5]}'
```

`running=1`, `desired=1`이고 deployment가 완료될 때까지 기다립니다. 새 태스크의 `proxysql` 컨테이너 health check와 `proxysql-bootstrap` 로그를 확인합니다. DB 네트워크 검사 컨테이너는 성공 후 종료되는 일회성 검사입니다.

```bash
aws logs tail /ecs/stockspoon-v2-prod/proxysql \
  --since 10m --follow --region ap-northeast-2
```

BE 태스크에서 새 DNS를 조회하고 TCP 6033 연결을 확인합니다. ECS Exec으로 새 ProxySQL에 접속해 6032 Admin에서 아래를 확인합니다. 앱 계정으로도 `SELECT @@hostname, @@server_id, @@read_only;`를 실행해 연결된 DB를 확인합니다. 이 확인에는 운영 테이블 쓰기를 발생시키지 않습니다.

```sql
SELECT hostgroup_id, hostname, port, status FROM runtime_mysql_servers;
SELECT * FROM runtime_mysql_replication_hostgroups;
SELECT hostname, port, read_only, error
  FROM monitor.mysql_server_read_only_log
  ORDER BY time_start_us DESC LIMIT 10;
```

새 태스크에서 앱·모니터 계정 인증이 성공하고, 두 DB 모니터링 오류가 없으며, 앱 연결이 `@@read_only=0`인 현재 Primary에 도착하는 것을 확인하기 전에는 주소를 바꾸지 않습니다. 이 단계에서 운영 DB에 임의의 쓰기 테스트는 하지 않습니다. ECS health check만으로 DB 사용자 인증이나 올바른 쓰기 대상을 증명하지는 않습니다.

## 2. Backend 연결 주소 전환

Fargate 검증이 끝난 뒤 Backend JDBC 주소 변경 계획을 확인합니다. endpoint는 코드에서 Fargate DNS로 고정되어 있으므로 별도 `backend_proxysql_target` 변수를 지정하지 않습니다. 평소 쓰는 로컬 변수 파일이 있으면 지정합니다.

```bash
terraform -chdir=ecs plan \
  -target=aws_ssm_parameter.backend_datasource_url \
  -out=/tmp/proxysql-fargate-cutover.tfplan

terraform -chdir=ecs show -no-color /tmp/proxysql-fargate-cutover.tfplan
```

이 계획에는 `SPRING_DATASOURCE_URL` 파라미터 값 변경만 있어야 합니다. 기존 ProxySQL·Backend·Frontend·DB가 변경되거나 삭제되면 적용하지 않습니다.

```bash
terraform -chdir=ecs apply /tmp/proxysql-fargate-cutover.tfplan
```

SSM 값 변경은 이미 실행 중인 Backend 태스크에 소급 적용되지 않습니다. Backend ECS 서비스에 새 배포를 시작해야 새 태스크가 SSM의 새 주소를 읽습니다. 평소 BE CD 배포를 사용하거나, 의도한 시점에 아래 명령으로 서비스를 재배포합니다.

```bash
aws ecs update-service --region ap-northeast-2 \
  --cluster stockspoon-v2-prod-cluster \
  --service stockspoon-v2-prod-backend \
  --force-new-deployment
```

배포 중 기존 태스크는 기존 ProxySQL에, 새 태스크는 Fargate ProxySQL에 연결됩니다. 두 ProxySQL 모두 같은 현재 DB 구성으로 쓰므로 DB 승격은 동시에 진행하지 않습니다. 새 Backend 태스크의 로그와 실제 DB `@@hostname`, `@@server_id`, `@@read_only`를 확인하고, 이전 Backend 태스크가 모두 종료된 뒤 Fargate 경로 전환이 끝난 것으로 봅니다.

## 롤백

기존 ProxySQL을 정리하기 전에는 SSM 주소를 기본값 `proxysql.stockspoon-v2.internal`로 되돌리는 계획을 만들고 적용한 뒤 Backend를 다시 배포하면 됩니다. 기존 서비스를 계속 켜두므로 DB 복구나 복제 방향 변경은 필요하지 않습니다. 롤백을 확인하기 전까지 Fargate 서비스를 삭제하지 않습니다.
