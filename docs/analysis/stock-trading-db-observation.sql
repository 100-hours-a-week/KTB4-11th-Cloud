-- 대상: 현재 BE Entity/DDL과 같은 스키마를 사용하는 MySQL 8.x.
-- 분석 준비용 읽기 전용 SELECT/EXPLAIN. 운영 DB에서 실행한 결과가 아니다.
-- 대상 데이터베이스를 선택한 연결에서 필요한 문장만 실행한다.
-- 집계는 대량 테이블을 읽을 수 있다. 범위/실행 시간은 운영 데이터량에 맞춘다.
-- performance_schema 조회는 해당 테이블의 SELECT 권한과 계측 설정이 필요하다.

-- 데이터베이스/서버 시각 확인. 날짜별 분석 전 저장된 created_at의 시간대와 비교한다.
SELECT DATABASE() AS selected_database, VERSION() AS mysql_version,
       @@session.time_zone AS session_time_zone,
       @@global.time_zone AS global_time_zone,
       CURRENT_TIMESTAMP AS session_now, UTC_TIMESTAMP() AS utc_now;

-- 현재 데이터 분포. 취소 주문도 보관량에 포함한다.
SELECT status, order_type, side,
       COUNT(*) AS order_rows,
       COUNT(DISTINCT account_id) AS account_count
FROM trade_orders
GROUP BY status, order_type, side
ORDER BY status, order_type, side;

-- 시세 처리의 핵심 변수 P_s: 종목별 대기 지정가 수.
SELECT stock_code, COUNT(*) AS pending_limit_orders,
       COUNT(DISTINCT account_id) AS accounts,
       MIN(created_at) AS oldest_pending_order
FROM trade_orders
WHERE status = 'PENDING' AND order_type = 'LIMIT'
GROUP BY stock_code
ORDER BY pending_limit_orders DESC, stock_code;

-- 정리 작업의 핵심 변수 A: 대기 주문 보유 계좌 수.
SELECT COUNT(*) AS pending_orders,
       COUNT(DISTINCT account_id) AS pending_accounts,
       COUNT(DISTINCT stock_code) AS pending_symbols
FROM trade_orders
WHERE status = 'PENDING';

-- 테이블 용량과 InnoDB 추정 행 수. table_rows는 정확한 COUNT가 아니다.
SELECT table_name, engine, table_rows AS estimated_rows,
       data_length AS data_bytes, index_length AS index_bytes,
       data_length + index_length AS allocated_bytes
FROM information_schema.tables
WHERE table_schema = DATABASE()
  AND table_name IN ('users', 'accounts', 'trade_orders', 'holdings',
                     'executions', 'ai_order_reports', 'ai_report_reasoning')
ORDER BY allocated_bytes DESC;

-- 실제 인덱스. 코드의 @Index 및 저장소 SQL과 운영 정의를 대조한다.
SELECT table_name, index_name, non_unique,
       GROUP_CONCAT(column_name ORDER BY seq_in_index SEPARATOR ', ') AS index_columns
FROM information_schema.statistics
WHERE table_schema = DATABASE()
  AND table_name IN ('trade_orders', 'accounts', 'holdings',
                     'executions', 'ai_order_reports', 'ai_report_reasoning')
GROUP BY table_name, index_name, non_unique
ORDER BY table_name, index_name;

-- 리포트 텍스트 바이트. 전체 집계이므로 필요하면 측정 범위를 제한한다.
SELECT COUNT(*) AS report_rows,
       AVG(OCTET_LENGTH(reason)) AS average_reason_bytes,
       MAX(OCTET_LENGTH(reason)) AS maximum_reason_bytes,
       SUM(OCTET_LENGTH(reason)) AS total_reason_bytes
FROM ai_order_reports;

SELECT COUNT(*) AS reasoning_rows,
       COUNT(DISTINCT report_id) AS reports_with_reasoning,
       AVG(OCTET_LENGTH(label) + OCTET_LENGTH(body)) AS average_text_bytes_per_item,
       SUM(OCTET_LENGTH(label) + OCTET_LENGTH(body)) AS total_text_bytes
FROM ai_report_reasoning;

-- 주문 생성 일자별 수. UTC/KST를 자동 추정하지 않고 저장 시각 기준으로 집계한다.
SELECT DATE(created_at) AS stored_date, order_type, status,
       COUNT(*) AS order_rows
FROM trade_orders
GROUP BY DATE(created_at), order_type, status
ORDER BY stored_date DESC, order_type, status;

-- 체결 일자별 행 증가량. 시장가 1건은 여러 체결 행을 가질 수 있다.
SELECT DATE(e.created_at) AS stored_date, o.order_type, o.side,
       COUNT(*) AS execution_rows,
       COUNT(DISTINCT e.order_id) AS executed_orders,
       COUNT(*) / COUNT(DISTINCT e.order_id) AS average_fills_per_order
FROM executions AS e
JOIN trade_orders AS o ON o.order_id = e.order_id
GROUP BY DATE(e.created_at), o.order_type, o.side
ORDER BY stored_date DESC, o.order_type, o.side;

-- 주요 조회의 계획만 확인한다. 종목코드는 실제 대기 주문이 있는 값으로 바꾼다.
-- 이것은 Repository JPQL의 주요 조건을 옮긴 예시이며 실제 Hibernate SQL 전체와 같지는 않다.
EXPLAIN
SELECT o.*, a.*
FROM trade_orders AS o
JOIN accounts AS a ON a.account_id = o.account_id
WHERE o.stock_code = '005930' AND o.status = 'PENDING' AND o.order_type = 'LIMIT';

EXPLAIN
SELECT DISTINCT account_id
FROM trade_orders
WHERE status = 'PENDING'
ORDER BY account_id;

EXPLAIN
SELECT DISTINCT stock_code
FROM trade_orders
WHERE status = 'PENDING';

-- 누적 SQL 통계. COUNT는 서버 통계 수집/초기화 이후 누적이며 바로 QPS를 뜻하지 않는다.
-- 두 시점의 COUNT 차이를 관찰 시간으로 나눠 실행 빈도를 구한다.
-- DIGEST_TEXT는 정규화된 SQL 템플릿이며 주문별 실제 값은 반환하지 않는다.
SELECT digest_text, count_star AS executions,
       sum_timer_wait / 1000000000000 AS cumulative_seconds,
       avg_timer_wait / 1000000000 AS average_ms,
       sum_rows_examined AS examined_rows,
       sum_rows_sent AS returned_rows
FROM performance_schema.events_statements_summary_by_digest
WHERE schema_name = DATABASE()
  AND (digest_text LIKE '%trade_orders%' OR digest_text LIKE '%accounts%'
       OR digest_text LIKE '%holdings%' OR digest_text LIKE '%executions%'
       OR digest_text LIKE '%ai_order_reports%' OR digest_text LIKE '%ai_report_reasoning%')
ORDER BY sum_timer_wait DESC
LIMIT 30;

-- 현재 관측되는 InnoDB 잠금 대기. 빈 결과가 과거의 잠금 대기 부재를 증명하지는 않는다.
SELECT requesting_thread_id, blocking_thread_id,
       requesting_engine_transaction_id, blocking_engine_transaction_id
FROM performance_schema.data_lock_waits;

-- 데이터 점검: PENDING 예약금이 현금을 초과하는 계좌.
-- 정상 거래 흐름에서는 이 결과가 없어야 한다.
SELECT a.account_id, a.cash_balance,
       COALESCE(SUM(o.reserved_cash), 0) AS pending_reserved_cash
FROM accounts AS a
LEFT JOIN trade_orders AS o
  ON o.account_id = a.account_id AND o.status = 'PENDING'
GROUP BY a.account_id, a.cash_balance
HAVING a.cash_balance < COALESCE(SUM(o.reserved_cash), 0);

-- 데이터 점검: EXECUTED 주문의 전량 체결 기록 누락/수량 불일치.
SELECT o.order_id, o.order_type, o.quantity AS ordered_quantity,
       COUNT(e.execution_id) AS execution_rows,
       COALESCE(SUM(e.execution_quantity), 0) AS executed_quantity
FROM trade_orders AS o
LEFT JOIN executions AS e ON e.order_id = o.order_id
WHERE o.status = 'EXECUTED'
GROUP BY o.order_id, o.order_type, o.quantity
HAVING COUNT(e.execution_id) = 0
    OR COALESCE(SUM(e.execution_quantity), 0) <> o.quantity;

-- 데이터 점검: 체결 완료/취소 주문에 예약금이 남아 있는지.
SELECT order_id, account_id, status, reserved_cash
FROM trade_orders
WHERE status IN ('EXECUTED', 'CANCELLED') AND reserved_cash <> 0;
