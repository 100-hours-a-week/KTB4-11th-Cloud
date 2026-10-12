분석 기준: 2026-10-12, `/Users/kimjihyeon/dev/KTB4-11th-BE`, 브랜치 `feat/cicd-V2dev`, 커밋 `3ff49c6`.

현재 체크아웃의 Java 구현을 읽은 정적 분석이다. 운영 V1의 배포 커밋·환경변수·실제 인덱스·QPS·데이터 용량은 확인하지 않았다. 문서에 지정가만 지원한다고 적힌 과거 설명이 있지만, 현재 `OrderController`에는 시장가와 지정가 경로가 모두 있다. 아래 판단은 현재 코드가 기준이다.

**서비스는 공통 외부 시세·호가를 참고해 계좌별로 모의 매매를 처리한다.** 사용자 A의 매수 주문과 사용자 B의 매도 주문을 서로 매칭하거나, 사용자 주문으로 외부 시장의 가격·잔량을 변경하는 구현은 없다. 키움 REST는 시세·종목정보 조회에 사용하며 실제 주문 API를 호출하지 않는다.

| 항목 | 공유 범위 | 구현상 의미 |
|---|---|---|
| 키움 WebSocket 연결·종목 구독 | 한 BE 인스턴스의 주문 전체 | 사용자별 연결이 아니라 주문 수요가 있는 종목들의 집합 |
| 현재가·10단계 호가 | BE 프로세스 메모리의 종목별 `Map` | DB에 시세 틱을 저장하지 않음 |
| 현금 잔액 | 계좌별 | `accounts.cash_balance` |
| 보유수량·취득원가 | 계좌·종목별 | `holdings(account_id, stock_code)` 유일 |
| 주문·예약금·체결·AI 리포트 | 계좌별 주문에 귀속 | 다른 사용자의 자산을 거래 상대편으로 사용하지 않음 |
| 호가 잔량 | 공통 스냅샷을 각 주문이 독립적으로 읽음 | 모의 체결 후 공통 호가 캐시의 잔량을 차감하지 않음 |

예를 들어 최신 호가에 매도 잔량 100주가 있을 때 서로 다른 두 계좌가 각각 80주를 매수하더라도, 각 주문은 동일 스냅샷의 100주를 기준으로 평가될 수 있다. 첫 주문이 두 번째 주문의 유동성을 소비하는 구현이 아니다. 지정가 체결은 호가 잔량 자체를 사용하지 않는다.

근거: [공통 메모리 상태](/Users/kimjihyeon/dev/KTB4-11th-BE/src/main/java/com/stock_spoon/river_be/market/kiwoom/KiwoomStockStream.java:40), [호가 복사와 체결 계산](/Users/kimjihyeon/dev/KTB4-11th-BE/src/main/java/com/stock_spoon/river_be/order/OrderExecutionService.java:109), [계좌·종목별 보유](/Users/kimjihyeon/dev/KTB4-11th-BE/src/main/java/com/stock_spoon/river_be/order/Holding.java:8), [시세 전용 키움 클라이언트](/Users/kimjihyeon/dev/KTB4-11th-BE/src/main/java/com/stock_spoon/river_be/market/kiwoom/KiwoomMarketClient.java:11).

**주문 생성은 AI 서버의 HTTP 요청으로 시작한다.** `POST /api/v1/accounts/{accountId}/orders`는 JWT의 `actor=AI`를 검사한다. 계좌 소유권, 활성 여부, AI 운용 여부, 종목코드, 수량, AI 판단 근거 등을 검증한다. 키움 종목정보의 시장 코드 `0` 또는 `8`을 허용한다.

BE는 주문 시점과 수량, 매수·매도 여부를 스스로 결정하는 AI 스케줄러를 포함하지 않는다. `GET /api/v1/users/ai-server`로 사용자·활성 AI 계좌·보유종목·대기 주문을 제공한다. AI가 언제 이 API를 호출하고 어떤 전략으로 주문을 만드는지는 이 저장소에서 확인할 수 없다. `holding_weight_limit_percent`, `is_lower_triggered`는 입력 검증과 리포트 저장에 사용되며, BE가 이를 이용해 추가 매매를 발동하거나 비중 상한을 체결 조건으로 강제하지 않는다.

근거: [AI 주문 인증 및 경로 분기](/Users/kimjihyeon/dev/KTB4-11th-BE/src/main/java/com/stock_spoon/river_be/order/OrderController.java:78), [주문 입력 검증](/Users/kimjihyeon/dev/KTB4-11th-BE/src/main/java/com/stock_spoon/river_be/order/OrderCreateRequest.java:26), [AI 사용자 스냅샷](/Users/kimjihyeon/dev/KTB4-11th-BE/src/main/java/com/stock_spoon/river_be/user/service/AiUserSnapshotService.java:39).

**지정가는 예약과 체결이 별도 트랜잭션이다.**

1. 시세 구독을 확보하고 등록 성공을 최대 10초 기다린다. 실패하면 주문 저장 작업을 실행하지 않는다.
2. 계좌에 비관적 쓰기 잠금을 잡는다.
3. 매수 가능 현금은 `현금 잔액 - PENDING 주문 예약금 합계`로 계산한다. 매도 가능 수량은 `현재 보유수량 - 해당 종목 PENDING 매도수량 합계`로 계산한다.
4. `trade_orders`에 PENDING 주문, AI 리포트와 상세 판단 항목을 저장한다. 이 단계에서는 실제 현금·보유량을 차감하지 않는다.
5. 저장 커밋 후 캐시 현재가를 확인하며, 없으면 키움 REST 현재가로 최초 체결 판단을 한다. 실패하면 주문은 PENDING으로 남는다.
6. 이후 해당 종목의 `StockPrice` 이벤트가 오면 모든 사용자 계좌의 대기 지정가 주문을 조회하고 각 주문을 별도 트랜잭션으로 판단한다.

| 주문 | 가격 조건 | 체결 방식 |
|---|---|---|
| 지정가 매수 | 현재가 ≤ 지정가 | 관측한 현재가로 주문 수량 전량 체결 |
| 지정가 매도 | 현재가 ≥ 지정가 | 관측한 현재가로 주문 수량 전량 체결 |

지정가 체결은 수신 거래량·호가 잔량·사용자 간 가격/시간 우선순위를 적용하지 않는다. 지정가 서비스는 처리 시각 기준 한국 시간 09:00 이상, 15:30 미만인지 확인하며 이전 날짜 주문 또는 15:30 이후 주문은 취소한다. 이벤트 수신 시각이 주문 생성 시각보다 앞선 이벤트는 건너뛴다. 현재가 캐시에는 시장가 호가와 같은 5초 신선도 제한이 없고, 연결 유효성과 등록 여부로 접근을 제한한다.

근거: [주문 예약 및 자원 확인](/Users/kimjihyeon/dev/KTB4-11th-BE/src/main/java/com/stock_spoon/river_be/order/OrderService.java:73), [최초 가격 판단과 이벤트 처리](/Users/kimjihyeon/dev/KTB4-11th-BE/src/main/java/com/stock_spoon/river_be/order/OrderExecutionListener.java:35), [지정가 체결 조건](/Users/kimjihyeon/dev/KTB4-11th-BE/src/main/java/com/stock_spoon/river_be/order/OrderExecutionService.java:233).

**시장가는 요청 중에 최신 호가로 전량 모의 체결한다.**

- 구독 성공 후 `latestOrderBook()`을 읽는다. 등록 성공이 호가 수신까지 보장하지 않으므로 호가가 아직 없으면 실패할 수 있다.
- 매수는 매도 호가를 싼 가격부터, 매도는 매수 호가를 비싼 가격부터 사용한다.
- 최대 10개 호가 단계의 잔량을 조합한다. 전체 수량을 충족하지 못하면 부분 체결을 남기지 않고 실패한다.
- 같은 날의 호가여야 하며 수신 시각과 호가 시각의 신선도를 검사한다. 과거 방향은 5초 범위, 호가 시각의 미래 오차는 최대 1초를 허용한다. 수신 시각 자체가 미래이면 거절한다.
- 현금·보유량과 PENDING 주문의 예약분을 확인한다.
- 한 트랜잭션에서 주문과 리포트 저장, 현금·보유량 변경, 호가 단계별 `executions` 저장, EXECUTED 전환을 수행한다.

시장가는 주문 1건당 체결 행이 1~10개가 될 수 있다. 모든 호가 단계는 한 번의 성공 트랜잭션에 포함된다. 매도 손익은 보유분의 총 취득원가를 수량 비율로 배분해 계산한다. 코드의 현금 이동은 체결 가격 × 수량이며 별도 수수료·세금 차감은 확인되지 않았다.

주문 생성·체결의 거래 시간 검사는 시간대 기준이다. 주말·공휴일·거래정지 상태를 체결 차단 조건으로 검사하는 구현은 확인되지 않았다. 코스피 지수 갱신에는 별도로 주말 검사가 있다.

근거: [시장가 시간·호가·자원 검사](/Users/kimjihyeon/dev/KTB4-11th-BE/src/main/java/com/stock_spoon/river_be/order/OrderExecutionService.java:92), [시장가 체결 저장](/Users/kimjihyeon/dev/KTB4-11th-BE/src/main/java/com/stock_spoon/river_be/order/OrderExecutionService.java:162), [주문 시간·시장 검사](/Users/kimjihyeon/dev/KTB4-11th-BE/src/main/java/com/stock_spoon/river_be/order/OrderMarketValidator.java:40).

**백그라운드 작업은 이벤트 처리와 주기 작업으로 나뉜다.**

| 실행 계기 | 처리 | DB 영향 |
|---|---|---|
| `0B` 시세 수신 | 해당 종목의 PENDING LIMIT 전체 조회 → 주문별 체결 판단 | 조회·계좌 잠금; 조건 충족 시 자산·체결·주문 상태 쓰기 |
| `0D` 호가 수신 | 종목별 호가 캐시 갱신 | 이 경로에서는 DB 접근 없음 |
| `OrderSubscriptionService.refresh()` 5초 fixedDelay | 만료 주문 정리 → 대기 주문 종목 목록과 접수 중 종목 합집합으로 구독 갱신 | 전체 PENDING 대상 조회·계좌 잠금; 만료 주문 상태 쓰기 |
| 애플리케이션 준비 완료 | `refresh()`로 만료 주문 정리와 구독 복구 | 위와 동일 |
| 주문 접수 임시 수요 해제 / 최초 판단 종료 / 이벤트에서 실제 체결 발생 | 주기 외에 `refresh()` 즉시 실행 | 주기 정리와 같은 전역 조회·잠금이 추가 발생 |
| `KiwoomStockStream.maintainConnection()` 5초 fixedDelay | 연결·로그인·구독 상태 확인 및 재연결 | 직접 DB 접근 없음 |
| 코스피 지수 기본 10초 fixedDelay | 평일 09:00~15:40 갱신; 초기값 없으면 장외에도 60초 이상 간격으로 시도 | REST 조회·메모리 캐시, 직접 DB 접근 없음 |

`fixedDelay`는 작업 완료 후 지정 지연을 두는 방식이므로 정확히 매 5초/10초마다 시작한다는 뜻은 아니다. 구독 refresh는 주기 외 직접 호출도 있다.

15:30 이후에는 오늘의 대기 주문을 취소하고 이전 날짜의 대기 주문은 시간과 관계없이 취소한다. CANCELLED 전환과 예약금 0 처리가 이루어지며 주문·리포트 행을 삭제하지 않는다. 모든 PENDING/접수 중 종목 수요가 없어지면 시세 연결을 닫고 가격·호가 캐시도 지운다. 따라서 사용자의 화면 접속 여부와 체결 작업 수명은 연결되어 있지 않다.

시세 연결은 `KIWOOM_STREAM_ENABLED` 활성화가 전제이며 저장소 설정의 기본값은 false다. 주문 정리 스케줄러에는 같은 활성화 조건이 없어 시세 연결 설정과 별도로 실행된다. 실제 운영 환경변수는 확인하지 않았다.

WebSocket 콜백은 시세를 파싱하고 캐시를 갱신한 뒤 가격 이벤트를 수신 순서대로 동기 처리한다. 다음 메시지 요청은 처리 후 진행한다. `@Async`, 메시지 브로커, 여러 BE의 체결 담당을 조정하는 분산 락/리더 선출은 현재 BE 코드에서 확인되지 않았다. 한 주문의 체결 실패는 잡아서 다음 주문을 계속 처리하지만, 느린 DB 접근이나 REST 가격 조회는 이후 시세 처리 지연으로 이어질 수 있다.

근거: [refresh 실행 계기와 종목 합집합](/Users/kimjihyeon/dev/KTB4-11th-BE/src/main/java/com/stock_spoon/river_be/order/OrderSubscriptionService.java:65), [만료 정리 조건](/Users/kimjihyeon/dev/KTB4-11th-BE/src/main/java/com/stock_spoon/river_be/order/OrderService.java:111), [시세 동기 처리](/Users/kimjihyeon/dev/KTB4-11th-BE/src/main/java/com/stock_spoon/river_be/market/kiwoom/KiwoomStockStream.java:395), [메시지 종류별 처리](/Users/kimjihyeon/dev/KTB4-11th-BE/src/main/java/com/stock_spoon/river_be/market/kiwoom/KiwoomStockStream.java:458), [연결 유지 조건](/Users/kimjihyeon/dev/KTB4-11th-BE/src/main/java/com/stock_spoon/river_be/market/kiwoom/KiwoomStockStream.java:181), [코스피 갱신](/Users/kimjihyeon/dev/KTB4-11th-BE/src/main/java/com/stock_spoon/river_be/market/KospiIndexService.java:37).

**핵심 부하는 체결되지 않은 주문의 반복 검사에서도 발생한다.**

가격 이벤트마다 `findPendingForPrice()`는 해당 종목의 모든 대기 지정가를 읽는다. 각 주문은 `executeLimit()`에서 계좌 잠금과 주문 재조회를 먼저 수행한 후에 가격 조건을 확인한다. 조건에 맞지 않는 주문도 이 접근을 수행한다. 따라서 주문 요청이 없어도 PENDING 주문이 남아 있고 시세가 계속 오면 조회·잠금 부하가 발생한다. 같은 가격의 후속 `0B` 이벤트를 생략하는 코드도 없다.

종목 s의 처리된 가격 이벤트 수를 `T_s` 회/초, 해당 종목의 이벤트 처리 대상 대기 주문 수를 `P_s`라 두면 체결 조건 불충족 상황의 주요 Repository 조회 모델은 다음과 같다.

```text
시세 처리 주요 조회/초 ≈ Σ_s T_s × (1 + 2 × P_s)
시세 처리 계좌 잠금 횟수/초 ≈ Σ_s T_s × P_s
```

`1`은 종목별 후보 조회, `2 × P_s`는 주문별 계좌 잠금 조회와 주문 재조회다. 새 주문보다 앞서 수신된 이벤트로 건너뛴 주문은 제외한다. 조건 충족 시 보유 조회·매수 평가용 조회·쓰기와 추가 refresh가 더해진다. 이 식은 측정된 SQL QPS가 아니라 주요 Repository 호출 모델이다. ORM 연관 로딩, flush, 트랜잭션 시작/종료, 처리 지연과 동시성에 따라 실제 SQL 수는 다르다.

예시로 이벤트를 초당 5회 처리하고 대기 주문 100건이 계속 조건을 만족하지 않으면 주요 조회 모델은 `5 × (1 + 200) = 1,005회/초`, 계좌 잠금은 500회/초다. 운영의 실제 이벤트 빈도나 주문 수를 뜻하는 수치는 아니다.

근거: [후보 전체 순회](/Users/kimjihyeon/dev/KTB4-11th-BE/src/main/java/com/stock_spoon/river_be/order/OrderExecutionListener.java:60), [후보 조회 조건](/Users/kimjihyeon/dev/KTB4-11th-BE/src/main/java/com/stock_spoon/river_be/order/OrderRepository.java:35), [가격 비교보다 앞선 계좌 잠금](/Users/kimjihyeon/dev/KTB4-11th-BE/src/main/java/com/stock_spoon/river_be/order/OrderExecutionService.java:233).

**주기 정리 작업은 여러 계좌의 잠금을 하나의 트랜잭션에서 보유한다.**

대기 주문이 있는 계좌 수가 A개일 때 refresh 1회당 주요 조회 모델은 `2 + 2A`다. PENDING 계좌 ID 목록 조회 1회, 계좌별 잠금과 PENDING 주문 조회 각 1회, PENDING 종목 목록 조회 1회로 구성된다. 취소할 주문이 없는 장중에도 계좌별 잠금과 조회를 수행하며, 정리 트랜잭션이 끝날 때까지 앞에서 잡은 계좌 잠금이 유지된다. 따라서 서로 다른 계좌의 개별 체결이 직접 같은 자산을 수정하지 않더라도 이 전역 정리 작업을 통해 대기할 수 있다.

주문 생성 1건에는 구독 확보 시 종목 목록 조회와 수요 해제 시 refresh가 포함된다. 지정가 최초 판단 종료 시 refresh도 다시 실행된다. 시세 처리 중 실제 체결이 있었던 이벤트도 refresh를 실행하므로 실제 refresh 빈도는 단순히 초당 0.2회로 잡을 수 없다.

근거: [전역 정리 트랜잭션과 계좌 순회](/Users/kimjihyeon/dev/KTB4-11th-BE/src/main/java/com/stock_spoon/river_be/order/OrderService.java:111), [직접 refresh 호출](/Users/kimjihyeon/dev/KTB4-11th-BE/src/main/java/com/stock_spoon/river_be/order/OrderSubscriptionService.java:70), [최초 판단과 체결 후 refresh](/Users/kimjihyeon/dev/KTB4-11th-BE/src/main/java/com/stock_spoon/river_be/order/OrderExecutionListener.java:37).

**저장 데이터의 증가량은 주문·체결·AI 근거를 나누어 계산해야 한다.** 아래는 논리적 변경 행이며 실제 SQL 문장 수를 의미하지 않는다.

| 계기 | 삽입 | 변경/삭제 |
|---|---|---|
| 지정가 예약 | 주문 1행, AI 리포트 1행, 상세 근거 R행 | 실제 현금·보유량 변화 없음 |
| 지정가 체결 | 체결 1행, 최초 보유 종목이면 holdings 1행 | 계좌 현금, 기존 보유량/원가, 주문 상태·예약금, 매수 후 평가 비중 |
| 시장가 성공 | 주문 1행, AI 리포트 1행, 상세 근거 R행, 체결 L행(1~10) | 계좌 현금, holdings 추가/변경/삭제, 주문 상태, 매수 후 평가 비중 |
| 수동 취소/만료 취소 | 없음 | 주문 상태·예약금·취소 시각 변경 |
| 전량 매도 | 체결 행 | 해당 계좌·종목 holdings 행 삭제 |

현재 거래 경로에는 주문·체결·리포트의 자동 보관기간 만료 삭제가 확인되지 않았다. CANCELLED 주문과 체결되지 않은 주문의 리포트도 저장량에 포함된다. holdings는 현재 보유 상태라 거래 이력과 같은 속도로 누적되지 않는다. 가격·호가 틱은 이 MySQL에 저장하지 않는다.

AI 리포트 `reason`은 최대 100,000자로 검증되는 MEDIUMTEXT이고 상세 근거의 `body`는 항목당 최대 16,000자다. 문자 수와 UTF-8 바이트 수는 다르다. 상세 항목 리스트 전체의 개수 상한은 입력 코드에서 확인되지 않았다. 따라서 주문 수뿐 아니라 평균 리포트 바이트, 항목 수, 실제 체결 단계 수가 용량·덤프·binlog 추정에 중요하다.

근거: [주문 상태와 예약금](/Users/kimjihyeon/dev/KTB4-11th-BE/src/main/java/com/stock_spoon/river_be/order/Order.java:112), [리포트와 상세 근거](/Users/kimjihyeon/dev/KTB4-11th-BE/src/main/java/com/stock_spoon/river_be/order/AiOrderReport.java:14), [상세 근거 크기](/Users/kimjihyeon/dev/KTB4-11th-BE/src/main/java/com/stock_spoon/river_be/order/ReportReasoning.java:9).

**읽기 API와 외부 REST 대기도 별도 부하 축이다.**

- AI 스냅샷은 활성 AI 계좌·보유·PENDING 주문·전체 사용자를 주요 4개 조회로 읽는다. 활성 계좌가 없을 때는 계좌와 사용자 조회만 한다. 페이지 분할은 없어 호출 빈도와 전체 사용자·계좌·보유·대기 주문 수가 중요하다.
- 주문 이력은 `page`가 있으면 DB 페이지를 적용한다. `page`가 없으면 `limit=10`이어도 전체 후보 주문과 체결을 읽은 뒤 애플리케이션에서 제한한다. 장기 보관량이 늘면 주요 읽기 경로가 될 수 있다.
- 계좌·보유 평가 API는 먼저 DB 값을 복사하고 트랜잭션 밖에서 키움 REST를 조회한다. 현재가가 변할 때마다 holdings에 평가손익을 쓰지는 않는다.
- 매수 체결 시 다른 보유종목 평가용 현재가를 REST로 순차 조회한다. 이 조회는 체결 트랜잭션 전이지만 시세 이벤트의 동기 처리 경로에는 포함된다.
- 키움 REST 클라이언트는 한 인스턴스에서 `synchronized`로 직렬 호출하고 각 응답 완료 후 220ms 간격을 둔다. API 지연이 곧 DB 병목이라는 판단은 피하고 외부 요청 대기와 DB 잠금 시간을 나누어 측정해야 한다.

근거: [AI 스냅샷 주요 조회](/Users/kimjihyeon/dev/KTB4-11th-BE/src/main/java/com/stock_spoon/river_be/user/service/AiUserSnapshotService.java:40), [주문 이력 페이지 조건](/Users/kimjihyeon/dev/KTB4-11th-BE/src/main/java/com/stock_spoon/river_be/order/OrderHistoryService.java:57), [DB 읽기 후 보유 평가](/Users/kimjihyeon/dev/KTB4-11th-BE/src/main/java/com/stock_spoon/river_be/account/service/AccountHoldingsService.java:54), [매수 평가용 조회](/Users/kimjihyeon/dev/KTB4-11th-BE/src/main/java/com/stock_spoon/river_be/order/OrderBuyPriceService.java:22), [REST 직렬 호출](/Users/kimjihyeon/dev/KTB4-11th-BE/src/main/java/com/stock_spoon/river_be/market/kiwoom/KiwoomMarketClient.java:148).

**인덱스는 운영 DB의 실제 정의와 실행 계획으로 확인해야 한다.** 현재 Entity와 제공 SQL에서 trade_orders의 명시적 인덱스는 `(account_id, status)`다. 시세 후보 조회의 `(stock_code, status, order_type)`나 전체 PENDING 조회를 지원하는 status 선두 인덱스는 제공 정의에서 확인되지 않았다. 실행 DB에 운영 중 추가한 인덱스가 있을 수 있으므로 full scan 또는 병목을 단정할 수는 없다. `SHOW INDEX`에 해당하는 관찰 SQL과 `EXPLAIN`을 준비했다.

**DB 전환 시 쓰기 발생원의 범위에 백그라운드 체결과 만료 취소를 포함해야 한다.** HTTP 주문 생성만 멈춰도 WebSocket 이벤트는 기존 대기 주문을 체결할 수 있고, 만료 정리도 주문을 수정할 수 있다. AI 요청, 주문 취소, 체결 이벤트, 만료 정리의 진행 중 트랜잭션을 정리한 뒤 기존 DB의 마지막 GTID를 확정해야 한다.

같은 DB를 사용하는 여러 BE가 동일 주문을 처리하면 계좌 잠금 후 주문 상태를 재확인해 중복 체결을 막도록 구현되어 있다. 하지만 서로 다른 DB의 잠금은 계좌에 대한 하나의 잠금으로 조정되지 않는다. 두 DB에서 같은 주문을 각각 처리할 수 있으므로, 이 서비스에서 보호해야 하는 정합성 대상은 계좌 현금·보유량·예약금·주문 상태·체결 이력이다. 시세 구독과 캐시는 프로세스 로컬이고 코드에도 단일 BE 가정이 명시돼 있어, DB 전환 중 두 BE의 백그라운드 담당을 함께 관리해야 한다.

이는 같은 order_id의 중복 체결을 막는 장치다. HTTP POST 재전송을 같은 요청으로 식별하는 멱등 키는 현재 주문 입력과 Controller에서 확인되지 않았다. 따라서 응답 타임아웃 후 재전송이 새 주문으로 생성되는 가능성은 별도로 고려해야 한다.

근거: [계좌 비관적 잠금](/Users/kimjihyeon/dev/KTB4-11th-BE/src/main/java/com/stock_spoon/river_be/account/repository/AccountRepository.java:12), [잠금 후 PENDING 재확인](/Users/kimjihyeon/dev/KTB4-11th-BE/src/main/java/com/stock_spoon/river_be/order/OrderExecutionService.java:237), [단일 BE 전제](/Users/kimjihyeon/dev/KTB4-11th-BE/src/main/java/com/stock_spoon/river_be/order/OrderSubscriptionService.java:28).

운영에서 우선 수집할 값은 종목별 처리 시세 이벤트/초, 종목별 PENDING 주문 수, PENDING 계좌 수, 실제 refresh 횟수·소요시간, 체결 성공/실패율, DB 문장별 실행 횟수·지연, 계좌 행 잠금 대기, 초당 생성 주문·체결 행 수, AI 근거의 평균 바이트, binlog 증가량이다. [관찰 SQL](/Users/kimjihyeon/dev/KTB4-11th-Cloud/docs/analysis/stock-trading-db-observation.sql)은 데이터 분포·용량·인덱스·누적 SQL 통계와 일부 정합성을 확인하기 위한 준비 파일이며 운영 DB에서 실행한 결과는 아니다. 가격 이벤트 빈도와 외부 AI 호출 주기는 별도 로그/지표로 수집해야 한다.
