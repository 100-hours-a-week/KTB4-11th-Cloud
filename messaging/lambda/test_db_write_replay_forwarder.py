import unittest
import sys
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


if __name__ == "__main__":
    unittest.main()
