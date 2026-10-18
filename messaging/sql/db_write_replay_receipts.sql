-- Run once against the V1 primary before enabling BE queue capture.
-- The table is included in GTID replication and is available after promotion.
-- The application user used by ProxySQL needs INSERT access to this table.
CREATE TABLE IF NOT EXISTS stockspoon.db_write_replay_receipts (
  request_id CHAR(36) NOT NULL,
  transaction_id VARCHAR(64) NOT NULL,
  applied_at TIMESTAMP(6) NOT NULL DEFAULT CURRENT_TIMESTAMP(6),
  PRIMARY KEY (request_id)
) ENGINE=InnoDB;
