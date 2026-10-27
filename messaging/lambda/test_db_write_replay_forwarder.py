import unittest
import io
import json
import sys
from contextlib import redirect_stdout
from datetime import datetime
from types import SimpleNamespace
from unittest.mock import patch

import db_write_replay_forwarder as replay


class RecordingCursor:
    def __init__(self):
        self.calls = []
        self.description = None

    def execute(self, sql, parameters=None):
        self.calls.append((sql, parameters))

    def nextset(self):
        return None


class RecordingSqs:
    def __init__(self, messages):
        self.messages = list(messages)
        self.deleted = []
        self.visibility_resets = []
        self.receive_count = 0

    def receive_message(self, **kwargs):
        self.receive_count += 1
        if not self.messages:
            return {}
        return {"Messages": [self.messages.pop(0)]}

    def delete_message(self, **kwargs):
        self.deleted.append(kwargs["ReceiptHandle"])

    def change_message_visibility(self, **kwargs):
        self.visibility_resets.append((kwargs["ReceiptHandle"], kwargs["VisibilityTimeout"]))


class RecordingContext:
    def get_remaining_time_in_millis(self):
        return 900_000


class RecordingConnection:
    def __init__(self, cursor):
        self.recording_cursor = cursor
        self.events = []

    def begin(self):
        self.events.append("begin")

    def cursor(self):
        return self.recording_cursor

    def commit(self):
        self.events.append("commit")

    def rollback(self):
        self.events.append("rollback")

    def close(self):
        self.events.append("close")


class ContextRecordingCursor(RecordingCursor):
    def __enter__(self):
        return self

    def __exit__(self, *_):
        return False


class DbWriteReplayForwarderTests(unittest.TestCase):
    def test_bind_operations_restore_ordered_values_and_nulls(self):
        parameters = replay._parameters_from_operations([
            {"method": "setString", "args": [
                {"type": "java.lang.Integer", "value": 1},
                {"type": "java.lang.String", "value": "005930"},
            ]},
            {"method": "setNull", "args": [
                {"type": "java.lang.Integer", "value": 2},
                {"type": "sqlType", "value": 12},
            ]},
            {"method": "setBigDecimal", "args": [
                {"type": "java.lang.Integer", "value": 3},
                {"type": "java.math.BigDecimal", "value": "10.25"},
            ]},
        ])

        self.assertEqual(parameters, ("005930", None, replay.Decimal("10.25")))

    def test_sql_conversion_skips_quoted_question_marks_and_escapes_percent(self):
        sql, count = replay._prepare_sql(
            "UPDATE orders SET note='why?', code=?, value LIKE '%?%' -- ?\nWHERE id=?",
            True,
        )

        self.assertEqual(count, 2)
        self.assertEqual(
            sql,
            "UPDATE orders SET note='why?', code=%s, value LIKE '%%?%%' -- ?\nWHERE id=%s",
        )

    def test_jdbc_parameter_sets_execute_in_their_original_order(self):
        cursor = RecordingCursor()
        statement = {
            "sql": "INSERT INTO orders (stock_code) VALUES (?)",
            "parameterSets": [
                [{"method": "setString", "args": [
                    {"type": "java.lang.Integer", "value": 1},
                    {"type": "java.lang.String", "value": "005930"},
                ]}],
                [{"method": "setString", "args": [
                    {"type": "java.lang.Integer", "value": 1},
                    {"type": "java.lang.String", "value": "000660"},
                ]}],
            ],
        }

        replay._execute_statement(cursor, statement)

        self.assertEqual(cursor.calls, [
            ("INSERT INTO orders (stock_code) VALUES (%s)", ("005930",)),
            ("INSERT INTO orders (stock_code) VALUES (%s)", ("000660",)),
        ])

    def test_placeholder_count_must_match_the_jdbc_bind_values(self):
        cursor = RecordingCursor()

        with self.assertRaisesRegex(ValueError, "bind count"):
            replay._execute_statement(cursor, {
                "sql": "UPDATE orders SET status=? WHERE id=?",
                "parameterSets": [[{
                    "method": "setString",
                    "args": [
                        {"type": "java.lang.Integer", "value": 1},
                        {"type": "java.lang.String", "value": "FILLED"},
                    ],
                }]],
            })

        self.assertEqual(cursor.calls, [])

    def test_manual_drain_deletes_committed_messages_in_fifo_receive_order(self):
        sqs = RecordingSqs([
            {"MessageId": "m1", "Body": '{"requestId":"r1"}', "ReceiptHandle": "h1"},
            {"MessageId": "m2", "Body": '{"requestId":"r2"}', "ReceiptHandle": "h2"},
        ])
        old_sqs, old_ssm = replay._sqs, replay._ssm
        replay._sqs, replay._ssm = sqs, object()
        try:
            original_executor = replay._execute_transaction
            replay._execute_transaction = lambda envelope: "applied"
            try:
                with patch.dict("os.environ", {"DB_WRITE_REPLAY_QUEUE_URL": "queue-url"}):
                    result = replay.handler({"maxMessages": 2}, RecordingContext())
            finally:
                replay._execute_transaction = original_executor
        finally:
            replay._sqs, replay._ssm = old_sqs, old_ssm

        self.assertEqual(result["status"], "message_limit")
        self.assertEqual(result["applied"], 2)
        self.assertEqual(sqs.deleted, ["h1", "h2"])

    def test_manual_drain_stops_at_first_failure_and_keeps_that_message(self):
        sqs = RecordingSqs([
            {"MessageId": "m1", "Body": '{"requestId":"r1"}', "ReceiptHandle": "h1"},
            {"MessageId": "m2", "Body": '{"requestId":"r2"}', "ReceiptHandle": "h2"},
        ])
        old_sqs, old_ssm = replay._sqs, replay._ssm
        replay._sqs, replay._ssm = sqs, object()
        original_executor = replay._execute_transaction

        def fail_on_second(envelope):
            if envelope["requestId"] == "r2":
                raise RuntimeError("database is not writable")
            return "applied"

        replay._execute_transaction = fail_on_second
        try:
            with patch.dict("os.environ", {"DB_WRITE_REPLAY_QUEUE_URL": "queue-url"}):
                result = replay.handler({"maxMessages": 2}, RecordingContext())
        finally:
            replay._execute_transaction = original_executor
            replay._sqs, replay._ssm = old_sqs, old_ssm

        self.assertEqual(result["status"], "blocked")
        self.assertEqual(result["processed"], 1)
        self.assertEqual(sqs.deleted, ["h1"])
        self.assertEqual(sqs.visibility_resets, [("h2", 0)])
        self.assertEqual(sqs.receive_count, 2)

    def test_transaction_receipt_and_sql_commit_together_through_proxysql(self):
        cursor = ContextRecordingCursor()
        connection = RecordingConnection(cursor)
        fake_pymysql = SimpleNamespace(
            err=SimpleNamespace(IntegrityError=type("IntegrityError", (Exception,), {})),
            connect=lambda **kwargs: connection,
        )
        envelope = {
            "schemaVersion": 2,
            "operation": "SQL_TRANSACTION",
            "requestId": "bf6490ad-11d9-4d83-a4be-d97dde73c6cb",
            "transactionId": "tx-1",
            "statements": [{"sql": "UPDATE orders SET status=? WHERE id=?", "parameterSets": [[
                {"method": "setString", "args": [
                    {"type": "java.lang.Integer", "value": 1},
                    {"type": "java.lang.String", "value": "FILLED"},
                ]},
                {"method": "setLong", "args": [
                    {"type": "java.lang.Integer", "value": 2},
                    {"type": "java.lang.Long", "value": 42},
                ]},
            ]]}],
        }
        with patch.dict(sys.modules, {"pymysql": fake_pymysql}), \
             patch.object(replay, "_database_auth", return_value=("user", "password")), \
             patch.dict("os.environ", {
                 "DB_WRITE_REPLAY_PROXYSQL_HOST": "proxysql.stockspoon-v2.internal",
                 "DB_WRITE_REPLAY_PROXYSQL_PORT": "6033",
                 "DB_WRITE_REPLAY_DATABASE": "stockspoon",
             }):
            result = replay._execute_transaction(envelope)

        self.assertEqual(result, "applied")
        self.assertEqual(connection.events, ["begin", "commit", "close"])
        self.assertTrue(cursor.calls[0][0].startswith("INSERT INTO db_write_replay_receipts"))

    def test_duplicate_receipt_skips_sql_and_returns_success_for_sqs_delete(self):
        class DuplicateReceiptError(Exception):
            pass

        class DuplicateCursor(ContextRecordingCursor):
            def execute(self, sql, parameters=None):
                self.calls.append((sql, parameters))
                raise DuplicateReceiptError(1062, "duplicate request id")

        cursor = DuplicateCursor()
        connection = RecordingConnection(cursor)
        fake_pymysql = SimpleNamespace(
            err=SimpleNamespace(IntegrityError=DuplicateReceiptError),
            connect=lambda **kwargs: connection,
        )
        envelope = {
            "schemaVersion": 2,
            "operation": "SQL_TRANSACTION",
            "requestId": "bf6490ad-11d9-4d83-a4be-d97dde73c6cb",
            "transactionId": "tx-1",
            "statements": [{"sql": "UPDATE orders SET status=? WHERE id=?", "parameterSets": [[]]}],
        }
        with patch.dict(sys.modules, {"pymysql": fake_pymysql}), \
             patch.object(replay, "_database_auth", return_value=("user", "password")), \
             patch.dict("os.environ", {
                 "DB_WRITE_REPLAY_PROXYSQL_HOST": "proxysql.stockspoon-v2.internal",
                 "DB_WRITE_REPLAY_PROXYSQL_PORT": "6033",
                 "DB_WRITE_REPLAY_DATABASE": "stockspoon",
             }):
            result = replay._execute_transaction(envelope)

        self.assertEqual(result, "duplicate")
        self.assertEqual(connection.events, ["begin", "rollback", "close"])
        self.assertEqual(len(cursor.calls), 1)


class ReceiptConflict(Exception):
    pass


class OrderCursor(ContextRecordingCursor):
    """Represent the locked account/order state returned by MySQL."""

    def __init__(self, status="CANCELLED", reserved_cash=0, cancelled_at=datetime(2026, 10, 26, 14, 0, 8),
                 owner=128, active=1, order_exists=True, duplicate=False):
        super().__init__()
        self.account = {"account_id": 19720, "user_id": owner, "is_active": active}
        self.order = {"order_id": 26285, "account_id": 19720, "status": status,
                      "reserved_cash": reserved_cash, "created_at": datetime(2026, 10, 26, 14, 0, 6),
                      "cancelled_at": cancelled_at} if order_exists else None
        self.duplicate = duplicate
        self.row = None

    def execute(self, sql, parameters=None):
        super().execute(sql, parameters)
        if sql.startswith("INSERT INTO db_write_replay_receipts") and self.duplicate:
            raise ReceiptConflict(1062, "duplicate request")
        if "FROM accounts WHERE" in sql:
            self.row = self.account if parameters == (self.account["account_id"],) else None
        elif "FROM trade_orders WHERE" in sql:
            self.row = self.order if self.order and parameters == (
                self.order["order_id"], self.order["account_id"]) else None
        else:
            self.row = None

    def fetchone(self):
        return self.row


class BusinessCommandReplayTests(unittest.TestCase):
    def envelope(self, request_id="49fa9956-b660-42f6-a277-db558a3daca9", account_id=19720):
        return {
            "schemaVersion": 3, "operation": "BUSINESS_COMMAND",
            "consumerContract": "DB_WRITE_BUSINESS_COMMAND_V1",
            "requestId": request_id, "transactionId": "tx-1",
            "idempotencyKey": "a" * 64, "payloadHash": "b" * 64,
            "idempotencyKeySource": "REQUEST", "requiresBusinessValidation": True,
            "capturedStatementsArePartial": True, "capturedStatements": [],
            "replaySafety": "NO_DML_OBSERVED", "replayPolicy": "REEXECUTE_COMMAND",
            "sourceTransactions": [],
            "businessCommand": {"type": "ORDER_CANCEL", "actor": {"userId": 128, "source": "USER"},
                                "target": {"accountId": account_id, "orderId": 26285},
                                "payload": {"status": "cancelled"}},
        }

    def drain(self, envelopes, cursors, delete_error=None, commit_error=None, max_messages=None):
        trace = []

        class TracedConnection(RecordingConnection):
            def commit(self):
                super().commit()
                trace.append("commit")
                if commit_error:
                    raise commit_error

        class TracedSqs(RecordingSqs):
            def delete_message(self, **kwargs):
                trace.append("delete")
                if delete_error:
                    raise delete_error
                super().delete_message(**kwargs)

        connections = [TracedConnection(cursor) for cursor in cursors]
        sqs = TracedSqs([
            {"MessageId": f"m{i}", "Body": json.dumps(envelope), "ReceiptHandle": f"h{i}",
             "Attributes": {"ApproximateReceiveCount": "1"}}
            for i, envelope in enumerate(envelopes)
        ])
        fake_pymysql = SimpleNamespace(err=SimpleNamespace(IntegrityError=ReceiptConflict))
        output = io.StringIO()
        with patch.dict(sys.modules, {"pymysql": fake_pymysql}), \
             patch.object(replay, "_connect_database", side_effect=connections), \
             patch.object(replay, "_aws_clients", return_value=(sqs, None)), \
             patch.dict("os.environ", {"DB_WRITE_REPLAY_QUEUE_URL": "queue-url"}), \
             redirect_stdout(output):
            result = replay.handler({"maxMessages": max_messages or len(envelopes)}, RecordingContext())
        events = [json.loads(line) for line in output.getvalue().splitlines()]
        return result, sqs, connections, events, trace

    def test_already_cancelled_commits_receipt_without_changing_order_and_continues_fifo(self):
        cancelled, pending = OrderCursor(), OrderCursor("PENDING", 1, None)
        original_order = dict(cancelled.order)
        result, sqs, connections, events, trace = self.drain(
            [self.envelope(), self.envelope("b22f75ff-5b88-4485-8b13-d9d2d9e76fa7")],
            [cancelled, pending])

        self.assertEqual((result["processed"], result["applied"], result["alreadySatisfied"]), (2, 1, 1))
        self.assertEqual(sqs.deleted, ["h0", "h1"])
        self.assertEqual(trace, ["commit", "delete", "commit", "delete"])
        self.assertEqual(cancelled.order, original_order)
        self.assertFalse(any(sql.startswith("UPDATE") for sql, _ in cancelled.calls))
        self.assertTrue(cancelled.calls[0][0].startswith("INSERT INTO db_write_replay_receipts"))
        self.assertEqual(connections[0].events, ["begin", "commit", "close"])
        self.assertTrue(any(sql.startswith("UPDATE trade_orders") for sql, _ in pending.calls))
        committed = [e for e in events if e["event"] == "db_write_business_command_committed"]
        self.assertEqual([e["outcome"] for e in committed], ["already_satisfied", "applied"])

    def test_cancelled_order_with_inconsistent_state_is_preserved_for_reconciliation(self):
        for cursor in [OrderCursor(reserved_cash=1), OrderCursor(cancelled_at=None)]:
            with self.subTest(order=cursor.order):
                result, sqs, connections, _, _ = self.drain([self.envelope()], [cursor])
                self.assertEqual(result["failureCategory"], "RECONCILIATION_REQUIRED")
                self.assertEqual(result["errorCode"], "CANCELLED_ORDER_STATE_INCONSISTENT")
                self.assertFalse(result["retryable"])
                self.assertEqual(sqs.deleted, [])
                self.assertEqual(connections[0].events, ["begin", "rollback", "close"])

    def test_cancel_does_not_acknowledge_another_users_or_inactive_account(self):
        for cursor, code in [(OrderCursor(owner=999), "FORBIDDEN_ACCOUNT"),
                             (OrderCursor(active=0), "ACCOUNT_NOT_FOUND")]:
            with self.subTest(code=code):
                result, sqs, connections, _, _ = self.drain([self.envelope()], [cursor])
                self.assertEqual(result["errorCode"], code)
                self.assertEqual(result["failureCategory"], "BUSINESS_CONFLICT")
                self.assertFalse(any("FROM trade_orders" in sql for sql, _ in cursor.calls))
                self.assertEqual(sqs.deleted, [])
                self.assertIn("rollback", connections[0].events)

    def test_cancel_does_not_acknowledge_missing_order_or_wrong_account(self):
        wrong_account = OrderCursor()
        wrong_account.order["account_id"] = 999
        for cursor in [OrderCursor(order_exists=False), wrong_account]:
            with self.subTest(order=cursor.order):
                result, sqs, _, _, _ = self.drain([self.envelope()], [cursor])
                self.assertEqual(result["errorCode"], "ORDER_NOT_FOUND")
                self.assertEqual(sqs.deleted, [])

    def test_executed_order_is_business_conflict_and_stops_before_next_message(self):
        result, sqs, connections, events, _ = self.drain(
            [self.envelope(), self.envelope("b22f75ff-5b88-4485-8b13-d9d2d9e76fa7")],
            [OrderCursor("EXECUTED"), OrderCursor()])

        self.assertEqual(result["status"], "blocked")
        self.assertEqual(result["failureCategory"], "BUSINESS_CONFLICT")
        self.assertEqual(result["errorCode"], "ORDER_NOT_PENDING")
        self.assertFalse(result["retryable"])
        self.assertEqual(sqs.deleted, [])
        self.assertEqual(sqs.receive_count, 1)
        self.assertEqual(sqs.visibility_resets, [("h0", 0)])
        self.assertEqual(connections[0].events, ["begin", "rollback", "close"])
        self.assertEqual(connections[1].events, [])
        summary = events[-1]
        self.assertEqual(summary["Blocked"], 1)
        self.assertEqual(summary["FailureCategory"], "BUSINESS_CONFLICT")
        self.assertEqual(summary["_aws"]["CloudWatchMetrics"][0]["Namespace"], "Stockspoon/DBWriteReplay")

    def test_same_receipt_after_redelivery_skips_account_and_order_execution(self):
        cursor = OrderCursor(duplicate=True)
        result, sqs, connections, _, _ = self.drain([self.envelope()], [cursor])
        self.assertEqual(result["duplicates"], 1)
        self.assertEqual(result["alreadySatisfied"], 0)
        self.assertEqual(len(cursor.calls), 1)
        self.assertEqual(connections[0].events, ["begin", "rollback", "close"])
        self.assertEqual(sqs.deleted, ["h0"])

    def test_delete_failure_preserves_committed_receipt_for_safe_redelivery(self):
        result, sqs, connections, _, _ = self.drain(
            [self.envelope()], [OrderCursor()], delete_error=TimeoutError("sqs timed out"))
        self.assertEqual(result["failureCategory"], "SQS_ERROR")
        self.assertEqual(result["processingStage"], "sqs_delete")
        self.assertTrue(result["dbCommitConfirmed"])
        self.assertEqual(connections[0].events, ["begin", "commit", "close"])
        self.assertEqual(sqs.deleted, [])
        self.assertEqual(sqs.visibility_resets, [("h0", 0)])

    def test_lost_commit_response_does_not_delete_or_claim_a_confirmed_commit(self):
        result, sqs, connections, _, _ = self.drain(
            [self.envelope()], [OrderCursor()], commit_error=Exception(2013, "commit response lost"))
        self.assertEqual(result["failureCategory"], "TRANSIENT_DB_ERROR")
        self.assertFalse(result["dbCommitConfirmed"])
        self.assertTrue(result["retryable"])
        self.assertEqual(result["processed"], 0)
        self.assertEqual(sqs.deleted, [])
        self.assertEqual(connections[0].events, ["begin", "commit", "rollback", "close"])

    def test_queue_empty_summary_counts_already_satisfied_without_counting_a_new_write(self):
        result, sqs, _, events, _ = self.drain([self.envelope()], [OrderCursor()], max_messages=2)
        self.assertEqual(result["status"], "queue_empty")
        self.assertEqual((result["processed"], result["applied"], result["alreadySatisfied"]), (1, 0, 1))
        self.assertEqual(sqs.receive_count, 3)
        self.assertEqual(events[-1]["AlreadySatisfied"], 1)
        self.assertEqual(events[-1]["Blocked"], 0)

    def test_sqs_permission_and_service_errors_have_distinct_retry_advice(self):
        for code, status, retryable in [("AccessDenied", 403, False),
                                        ("AWS.SimpleQueueService.NonExistentQueue", 400, False),
                                        ("InternalError", 500, True)]:
            with self.subTest(code=code):
                error = Exception("AWS exception body must not be logged")
                error.response = {"Error": {"Code": code}, "ResponseMetadata": {"HTTPStatusCode": status}}
                result, sqs, _, events, _ = self.drain([self.envelope()], [OrderCursor()], delete_error=error)
                self.assertEqual(result["errorCode"], code)
                self.assertEqual(result["failureCategory"], "SQS_ERROR")
                self.assertEqual(result["retryable"], retryable)
                self.assertTrue(result["dbCommitConfirmed"])
                self.assertEqual(sqs.deleted, [])
                self.assertNotIn("AWS exception body", json.dumps(events))

    def test_unsafe_original_transaction_is_preserved_before_opening_database(self):
        envelope = self.envelope()
        envelope["replaySafety"] = "UNCONFIRMED_OR_PARTIAL"
        result, sqs, connections, _, _ = self.drain([envelope], [OrderCursor()])
        self.assertEqual(result["failureCategory"], "RECONCILIATION_REQUIRED")
        self.assertEqual(connections[0].events, [])
        self.assertEqual(sqs.deleted, [])

    def test_mysql_failures_are_classified_without_logging_sql_or_bindings(self):
        class FailingCursor(OrderCursor):
            def execute(self, sql, parameters=None):
                raise Exception(self.error_code, "SQL and secret bindings must not be logged")

        for code, category, retryable in [(1290, "TRANSIENT_DB_ERROR", True),
                                           (2013, "TRANSIENT_DB_ERROR", True),
                                           (1213, "TRANSIENT_DB_ERROR", True),
                                           (1146, "DATABASE_ERROR", False)]:
            with self.subTest(code=code):
                cursor = FailingCursor()
                cursor.error_code = code
                result, sqs, connections, events, _ = self.drain([self.envelope()], [cursor])
                self.assertEqual(result["failureCategory"], category)
                self.assertEqual(result["retryable"], retryable)
                self.assertEqual(result["errorCode"], code)
                self.assertNotIn("secret bindings", json.dumps(events))
                self.assertEqual(sqs.deleted, [])
                self.assertIn("rollback", connections[0].events)

    def test_invalid_contract_is_not_classified_as_a_business_conflict(self):
        envelope = self.envelope()
        envelope["consumerContract"] = "unknown"
        result, sqs, connections, _, _ = self.drain([envelope], [OrderCursor()])
        self.assertEqual(result["failureCategory"], "INVALID_COMMAND")
        self.assertFalse(result["retryable"])
        self.assertEqual(connections[0].events, [])
        self.assertEqual(sqs.deleted, [])


if __name__ == "__main__":
    unittest.main()
