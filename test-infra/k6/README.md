# 주문 DB 전환 유실 측정 시나리오

`order-promotion-loss.js`는 V1의 `POST /api/v1/accounts/{accountId}/orders`만 반복 호출한다. 장외 지정가 매수 주문을 계좌별로 만들고, 요청마다 고유한 `reason` 표식을 저장해 실행 로그와 V1·승격 DB의 주문 행을 대조한다. 취소, 조회, 체결 API는 호출하지 않는다.

현재 `dev`의 주문 흐름은 장외 지정가 접수를 허용한다. 시장가 접수는 비활성화되어 있다. 장외에 생성된 주문은 접수 직후 체결 판단을 건너뛰고 `PENDING`으로 저장되며, 새 장중 시세가 들어오기 전까지 대기한다. 기본 매수가 `1원`이라 정상적인 주가에서는 이후에도 체결되지 않으며, 각 주문은 매수 예약금 1원을 남긴다.

각 API 요청은 주문 예약 트랜잭션에서 `trade_orders`와 `ai_order_reports`를 함께 저장한다. 요청마다 다른 `reason`을 사용하므로 V1과 승격 DB에서 성공·유실 표식을 대조할 수 있다.

## 실행 전 조건

- 테스트용 `actor=AI` access token과 그 토큰 소유자의 활성 AI 계좌 ID를 준비한다.
- 계좌가 현재 진행 중인 대결에 참여하고 있어야 한다.
- 테스트 계좌를 사용한다. 주문은 DB에 남고 각 pending 매수 주문이 1원을 예약한다.
- 부하 발생기는 V1 Backend에 네트워크 접근할 수 있는 EC2에서 실행한다. 사설 주소를 쓰려면 해당 EC2와 V1 사이 라우팅 및 보안그룹 허용이 이미 있어야 한다. 부하 발생기와 DB 전환 작업은 별도로 수동 진행한다.
- 기본 속도는 초당 1건, 기본 시간은 10분이다. `K6_RATE`로 속도를 바꿀 수 있지만 주문 API는 요청마다 Kiwoom `ka10100` 종목정보도 확인하므로 처음에는 기본값으로 시작한다.

## 실행

먼저 이 파일을 V1 Backend에 연결 가능한 k6 EC2로 복사하고 접속한다.

```bash
scp -i <EC2_KEY.pem> test-infra/k6/order-promotion-loss.js \
  ubuntu@<K6_EC2_PUBLIC_IP>:/home/ubuntu/order-promotion-loss.js
ssh -i <EC2_KEY.pem> ubuntu@<K6_EC2_PUBLIC_IP>
```

k6 EC2에서 환경 변수를 설정해 실행한다. access token은 터미널 입력 기록에 남기지 않도록 `read -s`로 입력한다.

```bash
export K6_BASE_URL='http://<V1 backend 주소>:8080'
export K6_ACCOUNT_IDS='<AI 계좌 ID>'
export K6_STOCK_CODE='005930'
export K6_STOCK_NAME='삼성전자'
export K6_LIMIT_PRICE='1'
export K6_RUN_ID='migration-20261016-01'
export K6_RATE='1'
export K6_DURATION='10m'
export K6_PRE_ALLOCATED_VUS='2'
export K6_MAX_VUS='10'
export K6_CONFIRM_ORDER_WRITES='YES'
read -s K6_ACCESS_TOKEN
export K6_ACCESS_TOKEN
set -o pipefail
mkdir -p /home/ubuntu/order-loss-results
k6 run --summary-export="/home/ubuntu/order-loss-results/order-loss-${K6_RUN_ID}-summary.json" \
  /home/ubuntu/order-promotion-loss.js 2>&1 \
  | tee "/home/ubuntu/order-loss-results/order-loss-${K6_RUN_ID}.log"
```

여러 테스트 계좌가 같은 AI token 소유라면 `K6_ACCOUNT_IDS='101,102,103'`처럼 쉼표로 지정한다. k6 VU를 계좌에 분산해 한 계좌 행의 잠금 대기만으로 부하가 제한되는 현상을 줄일 수 있다. 한 번의 실행 안에서는 `K6_RUN_ID`를 고정하고, 별도 k6 프로세스를 동시에 실행한다면 실행마다 다른 ID를 사용한다.

각 주문은 `ORDER_ATTEMPT` 로그 줄에서 전송 전에 표식을 남기고, 응답 후 `ORDER_RESULT` 줄에 HTTP 상태와 `order_id`를 남긴다. 자동 재시도는 하지 않는다. HTTP timeout이나 5xx는 DB commit 이후 응답만 유실되었을 수도 있으므로 실패로 단정하지 않고 DB에서 표식을 확인한다.

## DB에 저장된 주문 확인

아래 쿼리를 V1 DB와 승격 후 새 Primary 양쪽에서 실행한다. `<RUN_ID>`는 `K6_RUN_ID`, `<ACCOUNT_ID>`는 확인할 계좌 ID로 바꾼다.

```sql
SELECT
  o.order_id,
  o.account_id,
  o.status,
  o.created_at,
  o.stock_code,
  o.limit_price,
  o.quantity,
  o.reserved_cash,
  r.reason
FROM trade_orders AS o
JOIN ai_order_reports AS r ON r.order_id = o.order_id
WHERE o.account_id = <ACCOUNT_ID>
  AND r.reason LIKE 'k6-migration-<RUN_ID>:%'
ORDER BY o.order_id;
```

실행별 저장 건수와 상태를 빠르게 확인하려면 다음 쿼리를 쓴다.

```sql
SELECT o.status, COUNT(*) AS order_count
FROM trade_orders AS o
JOIN ai_order_reports AS r ON r.order_id = o.order_id
WHERE r.reason LIKE 'k6-migration-<RUN_ID>:%'
GROUP BY o.status;
```

k6 로그의 `ORDER_ATTEMPT` 표식 전체와 DB에 남은 `reason` 표식을 비교한다. HTTP 201인데 승격 DB에 없는 표식은 응답이 확인된 요청 중 승격 DB에서 사라진 주문이다. timeout·5xx 표식은 V1과 승격 DB를 모두 확인해 commit 여부를 판별한다. HTTP 4xx는 인증·대결·입력 검증 등으로 거절된 요청이므로 유실 건수에 포함하지 않는다.
