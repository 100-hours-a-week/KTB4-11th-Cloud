"""Failure injection for promotion boundaries. No AWS or production DB calls."""
import importlib.util
import json
from pathlib import Path
import sys
import tempfile
import time
import unittest
from unittest.mock import Mock, patch

sys.path.insert(0, str(Path(__file__).parents[1]))
spec = importlib.util.spec_from_file_location("switchover", Path(__file__).parents[1] / "switchover.py")
m = importlib.util.module_from_spec(spec)
spec.loader.exec_module(m)

OLD = "source:1-171"
EXTRA = "seed:1-7"
BASE = OLD + "," + EXTRA


def subtract(a, b):
    def parse(value):
        result = {}
        for segment in value.split(","):
            if not segment:
                continue
            sid, *ranges = segment.split(":")
            values = set()
            for interval in ranges:
                ends = list(map(int, interval.split("-")))
                values.update(range(ends[0], ends[-1] + 1))
            result[sid] = values
        return result
    left, right = parse(a), parse(b)
    segments = []
    for sid, values in left.items():
        values = sorted(values - right.get(sid, set()))
        ranges = []
        for v in values:
            if ranges and v == ranges[-1][1] + 1:
                ranges[-1][1] = v
            else:
                ranges.append([v, v])
        if ranges:
            segments.append(sid + ":" + ":".join(str(lo) if lo == hi else f"{lo}-{hi}" for lo, hi in ranges))
    return ",".join(segments)


def replication_status(uuid, running=True):
    return dict(Channel_Name="", SQL_Delay=0, Skip_Counter=0, Last_IO_Errno=0, Last_SQL_Errno=0,
                Replica_IO_Running="Yes" if running else "No", Replica_SQL_Running="Yes" if running else "No",
                Source_UUID=uuid, Source_Host="10.0.1.246" if uuid == "source" else "10.0.1.217",
                Source_Port=3306, Source_User="forward" if uuid == "source" else "reverse",
                Auto_Position=1 if uuid == "source" else 0, Source_SSL_Allowed="Yes",
                Source_SSL_Verify_Server_Cert="No", Retrieved_Gtid_Set="",
                Connect_Retry=60, Source_Retry_Count=10)


class Database:
    def __init__(self, name, events, ro, gtids):
        self.name, self.events, self.ro, self.sro, self.gtids = name, events, ro, ro, gtids
        self.channel = []
        self.catchup = 0
        self.fail_start = False
        self.fail_reset = False
        self.fail_open = False
        self.lock_owned = 1
        self.other_uuid = "target" if name == "source" else "source"

    def rows(self, sql, params=()):
        self.events.append((self.name, sql, params))
        if sql == "SHOW REPLICA STATUS":
            return self.channel
        if sql == "SHOW BINARY LOG STATUS":
            return [{"File": "migration-bin.000003", "Position": 900, "Executed_Gtid_Set": self.gtids,
                     "Binlog_Do_DB": "", "Binlog_Ignore_DB": ""}]
        if sql.startswith("SELECT @@read_only"):
            return [{"ro": self.ro, "sro": self.sro}]
        if sql.startswith("SELECT @@global.relay_log_basename"):
            return [{"base": "/var/lib/mysql/current-relay", "idx": "/var/lib/mysql/current-relay.index"}]
        if sql == "STOP REPLICA":
            self.channel = [replication_status(self.other_uuid, False)]
        elif sql == "RESET REPLICA ALL":
            if self.fail_reset:
                raise RuntimeError("applier metadata reset failed")
            self.channel = []
        elif sql.startswith("CHANGE REPLICATION SOURCE"):
            self.channel = [{**replication_status(self.other_uuid, False),
                             "Source_Host": params[0], "Source_Port": params[1], "Source_User": params[2],
                             "Auto_Position": 1 if "SOURCE_AUTO_POSITION=1" in sql else 0}]
        elif sql == "START REPLICA":
            if self.fail_start:
                raise RuntimeError("replication authentication failure")
            self.channel[0]["Replica_IO_Running"] = "Yes"
            self.channel[0]["Replica_SQL_Running"] = "Yes"
        elif sql == "SET PERSIST read_only=ON":
            self.ro = 1
        elif sql == "SET PERSIST super_read_only=ON":
            self.ro = self.sro = 1
        elif sql == "SET PERSIST super_read_only=OFF":
            self.sro = 0
        elif sql == "SET PERSIST read_only=OFF":
            self.ro = self.sro = 0
            if self.fail_open:
                raise TimeoutError("response lost after write enable")
        return []

    def scalar(self, sql, params=()):
        self.events.append((self.name, sql, params))
        if "IS_USED_LOCK" in sql:
            return self.lock_owned
        if "WAIT_FOR_EXECUTED" in sql:
            return self.catchup
        if sql == "SELECT @@GLOBAL.gtid_executed":
            return self.gtids
        if "GTID_SUBSET" in sql:
            return 1
        if "GTID_SUBTRACT" in sql:
            a = params[0]
            b = params[1] if len(params) == 2 else self.gtids
            return subtract(a, b)
        return 1


class ReplicationAccountAuditTests(unittest.TestCase):
    def fake_db(self, account_rows, grant_rows=None):
        db = Mock()
        db.connection.escape.side_effect = lambda value: "'" + value.replace("'", "\\'") + "'"
        db.rows.side_effect = [account_rows] + (grant_rows or [])
        return db

    def test_replication_account_requires_unlocked_matching_host_and_global_privilege(self):
        db = self.fake_db(
            [dict(user="switchover_reverse", host="10.0.1.%", account_locked="N", ssl_type="ANY")],
            [[{"grants": "GRANT REPLICATION SLAVE ON *.* TO `switchover_reverse`@`10.0.1.%`"}]],
        )
        audit = m.replication_source_account_audit(db, "switchover_reverse", "10.0.1.246")
        self.assertTrue(audit[0]["replica_host_matches"])
        self.assertTrue(audit[0]["has_replication_privilege"])

    def test_missing_replication_account_fails_with_safe_account_diagnostics(self):
        db = self.fake_db([])
        with self.assertRaisesRegex(m.SafetyError, "switchover_reverse.*10.0.1.246"):
            m.replication_source_account_audit(db, "switchover_reverse", "10.0.1.246")

    def test_locked_or_wrong_host_account_is_rejected(self):
        db = self.fake_db(
            [dict(user="switchover_reverse", host="10.0.2.246", account_locked="Y", ssl_type="ANY")],
            [[{"grants": "GRANT REPLICATION SLAVE ON *.* TO `switchover_reverse`@`10.0.2.246`"}]],
        )
        with self.assertRaises(m.SafetyError):
            m.replication_source_account_audit(db, "switchover_reverse", "10.0.1.246")


class SwitchTests(unittest.TestCase):
    def setUp(self):
        self.events = []
        self.a = Database("source", self.events, 0, OLD)
        self.b = Database("target", self.events, 1, BASE)
        self.b.channel = [replication_status("source")]
        self.cfg = dict(schema="stockspoon", sync_timeout_seconds=0, routing_timeout_seconds=0, cutover_timeout_seconds=30,
                        source=dict(uuid="source", server_host="10.0.1.246", server_port=3306),
                        target=dict(uuid="target", server_host="10.0.1.217", server_port=3306),
                        proxy_app=dict(user="stockspoon"),
                        reverse_replication=dict(user="reverse", password_env="R"),
                        forward_replication=dict(user="forward", password_env="F"))
        self.journal = Mock()
        self.journal.state = {}
        self.journal.event.side_effect = lambda phase, **kw: self.events.append(("journal", phase, kw))
        self.flow = m.Switch(self.cfg, {"source": self.a, "target": self.b, "proxy_admin": Mock()},
                             Mock(), {"R": "secret-r", "F": "secret-f"}, self.journal)
        self.flow.preflight = Mock()
        self.flow.routes = Mock()
        self.flow.app_probe = Mock(return_value={"ro": 0})
        self.compare = patch.object(m, "compare_data", return_value={"orders": {"rows": 20, "checksum": 567}})
        self.compare.start()
        self.addCleanup(self.compare.stop)

    def index(self, name, sql):
        return next(i for i, event in enumerate(self.events) if event[:2] == (name, sql))

    # Retired integration tests retained as reference while replay is disabled.
#     def test_replay_recovery_starts_after_write_measurement_and_can_outlive_cutover_budget(self):
#         self.cfg["write_replay"] = {"function_name": "stockspoon-v2-prod-db-write-replay-forwarder"}
#
#         def recover(*_):
#             self.assertEqual((self.a.ro, self.b.ro), (1, 0))
#             self.assertIn("write_availability_window", self.journal.state)
#             self.flow.deadline = time.monotonic() - 1
#             return {"status": "queue_empty", "drainComplete": True, "processed": 101}
#
#         with patch.object(m, "drain_aws", side_effect=recover) as invoked:
#             self.flow.run()
#         invoked.assert_called_once()
#         self.assertFalse(self.journal.state["requires_attention"])
#         self.assertEqual(self.journal.state["write_replay"]["processed"], 101)
#         self.assertLess(self.index("journal", "proxy_writer_ready"),
#                         self.index("journal", "write_replay_recovery_started"))
#
#     def test_blocked_replay_keeps_promoted_writer_and_marks_recovery_incomplete(self):
#         self.cfg["write_replay"] = {"function_name": "stockspoon-v2-prod-db-write-replay-forwarder"}
#         with patch.object(m, "drain_aws", return_value={"status": "blocked", "drainComplete": False}):
#             self.flow.run()
#         self.assertEqual((self.a.ro, self.b.ro), (1, 0))
#         self.assertEqual(self.journal.state["status"], "complete")
#         self.assertTrue(self.journal.state["requires_attention"])
#
#     def test_rollback_never_invokes_replay_recovery(self):
#         self.a.gtids = BASE
#         self.cfg["write_replay"] = {"function_name": "stockspoon-v2-prod-db-write-replay-forwarder"}
#         self.flow.restore_state = {"target_only_gtids_at_switch": "", "before": {"replica": replication_status("source")}}
#         with patch.object(m, "drain_aws") as invoked:
#             self.flow.run()
#         invoked.assert_not_called()
#         self.assertEqual(self.journal.state["write_replay"]["status"], "not_invoked_rollback")
#

    def test_success_checks_data_and_starts_reverse_before_enabling_new_writer(self):
        self.flow.run()
        self.assertEqual((self.a.ro, self.a.sro, self.b.ro, self.b.sro), (1, 1, 0, 0))
        self.assertEqual(self.journal.state["target_only_gtids_at_switch"], EXTRA)
        self.assertEqual(self.journal.state["status"], "complete")
        window = self.journal.state["write_availability_window"]
        self.assertGreaterEqual(window["duration_seconds"], 0)
        self.assertEqual(window["start_boundary"], "current primary SET PERSIST read_only=ON succeeded")
        self.assertEqual(window["end_boundary"],
                         "ProxySQL roles are correct and a fresh app connection reaches the promoted DB with read_only=0")
        self.assertLess(self.index("journal", "write_blocked_started"),
                        self.index("journal", "proxy_writer_ready"))
        self.assertLess(self.index("journal", "data_verified"), self.index("source", "START REPLICA"))
        self.assertLess(self.index("journal", "data_verified"), self.index("target", "RESET REPLICA ALL"))
        self.assertLess(self.index("journal", "data_verified"), self.index("source", "RESET REPLICA ALL"))
        source_change = next(i for i, e in enumerate(self.events)
                             if e[0] == "source" and e[1].startswith("CHANGE REPLICATION SOURCE"))
        self.assertLess(self.index("source", "RESET REPLICA ALL"), source_change)
        self.assertLess(self.index("target", "RESET REPLICA ALL"), source_change)
        self.assertLess(self.index("source", "START REPLICA"), self.index("target", "SET PERSIST read_only=OFF"))
        self.assertLess(self.index("journal", "promotion_attempted"), self.index("target", "SET PERSIST super_read_only=OFF"))
        change = next(e for e in self.events if e[1].startswith("CHANGE REPLICATION"))
        self.assertIn("SOURCE_AUTO_POSITION=0", change[1])
        self.assertEqual(change[2][-2:], ("migration-bin.000003", 900))
        observed = [e for e in self.events if e[:2] == ("journal", "relay_paths_observed")]
        self.assertEqual(len(observed), 2)
        self.assertTrue(all(e[2]["base"] == "/var/lib/mysql/current-relay" for e in observed))
        self.assertTrue(all(e[2]["idx"] == "/var/lib/mysql/current-relay.index" for e in observed))
        self.assertEqual(sum(e[1] == "SET PERSIST_ONLY relay_log_recovery=ON" for e in self.events), 2)
        self.assertFalse(any(e[1].startswith("SET PERSIST_ONLY relay_log=")
                             or e[1].startswith("SET PERSIST_ONLY relay_log_index=")
                             for e in self.events))
        self.assertEqual(sum(e[1] == "RESET REPLICA ALL" for e in self.events), 2)
        self.assertEqual(sum(e[:2] == ("journal", "replica_metadata_reset_complete") for e in self.events), 2)

    def test_write_blocked_duration_stops_before_ready_result_is_recorded(self):
        timings = {}

        def record_event(phase, **values):
            if phase == "write_blocked_started":
                timings["start_marker"] = time.monotonic()
            elif phase == "proxy_writer_ready":
                # Simulate slow result serialization after the end timestamp
                # has been captured. It must not inflate the reported window.
                time.sleep(0.2)
                timings["ready_event_return"] = time.monotonic()
            self.events.append(("journal", phase, values))

        self.journal.event.side_effect = record_event
        self.flow.run()

        duration = self.journal.state["write_availability_window"]["duration_seconds"]
        recording_delay = timings["ready_event_return"] - timings["start_marker"] - duration
        self.assertGreaterEqual(recording_delay, 0.15)

    def test_lag_timeout_keeps_both_fenced_and_never_promotes(self):
        self.b.catchup = 1
        with self.assertRaisesRegex(m.SafetyError, "catch-up"):
            self.flow.run()
        self.assertEqual((self.a.ro, self.b.sro), (1, 1))
        self.assertFalse(any("=OFF" in e[1] for e in self.events))

    def test_data_mismatch_never_repoints_or_promotes(self):
        with patch.object(m, "compare_data", side_effect=m.SafetyError("checksum mismatch")):
            with self.assertRaisesRegex(m.SafetyError, "checksum"):
                self.flow.run()
        self.assertFalse(any(e[1].startswith("CHANGE REPLICATION") or e[1] == "SET PERSIST read_only=OFF" for e in self.events))

    def test_reverse_authentication_error_prevents_promotion(self):
        self.a.fail_start = True
        with self.assertRaisesRegex(RuntimeError, "authentication"):
            self.flow.run()
        self.assertEqual((self.a.sro, self.b.sro), (1, 1))

    def test_applier_metadata_reset_failure_prevents_source_change_and_promotion(self):
        self.a.fail_reset = True
        with self.assertRaisesRegex(RuntimeError, "metadata reset"):
            self.flow.run()
        self.assertFalse(any(e[0] == "source" and e[1].startswith("CHANGE REPLICATION SOURCE") for e in self.events))
        self.assertEqual((self.a.sro, self.b.sro), (1, 1))

    def test_unknown_promotion_result_does_not_reopen_old_primary(self):
        self.b.fail_open = True
        with self.assertRaises(TimeoutError):
            self.flow.run()
        self.assertEqual(self.a.sro, 1)
        self.assertFalse(any(e[:2] == ("source", "SET PERSIST read_only=OFF") for e in self.events))
        self.assertEqual(self.b.ro, 0)  # Simulates a committed command with its reply lost.

    def test_routing_failure_after_promotion_does_not_reverse_roles(self):
        self.flow.routes.side_effect = lambda writer: (_ for _ in ()).throw(m.SafetyError("routing")) if writer else None
        with self.assertRaisesRegex(m.SafetyError, "routing"):
            self.flow.run()
        self.assertEqual((self.a.sro, self.b.ro), (1, 0))

    def test_lost_control_lock_prevents_fencing(self):
        self.a.lock_owned = 0
        with self.assertRaisesRegex(m.SafetyError, "lock lost"):
            self.flow.run()
        self.assertFalse(any(e[1].startswith("SET PERSIST") for e in self.events))

    def test_restore_uses_recorded_exemption_and_returns_to_gtid_replication(self):
        self.a.ro = self.a.sro = 1
        self.b.ro = self.b.sro = 0
        self.a.channel = [replication_status("target")]
        self.b.channel = [replication_status("source", False)]
        # Five transactions accepted by the migration primary during the rehearsal.
        self.a.gtids = OLD + ",seed:8-12"
        self.b.gtids = OLD + ",seed:1-12"
        prior = dict(target_only_gtids_at_switch=EXTRA, before={"replica": dict(Connect_Retry=60, Source_Retry_Count=10)})
        flow = m.Switch(self.cfg, {"source": self.a, "target": self.b, "proxy_admin": Mock()},
                        Mock(), {"F": "secret-f"}, self.journal, prior)
        flow.preflight, flow.routes = Mock(), Mock()
        flow.app_probe = Mock(return_value={"ro": 0})
        flow.run()
        waits = [e for e in self.events if "WAIT_FOR_EXECUTED_GTID_SET" in e[1]]
        self.assertEqual(waits[0][2], (OLD + ",seed:8-12",))
        change = next(e for e in self.events if e[1].startswith("CHANGE REPLICATION"))
        self.assertIn("SOURCE_AUTO_POSITION=1", change[1])
        self.assertNotIn("SOURCE_LOG_POS", change[1])
        self.assertEqual(change[2][-2:], (60, 10))
        self.assertEqual((self.a.ro, self.b.sro), (0, 1))
        self.assertTrue(any(e[1] == "RESET REPLICA ALL" for e in self.events))
        self.assertFalse(any("gtid_purged" in e[1].lower() or "reset binary logs" in e[1].lower() for e in self.events))

    def test_reverse_start_failure_persists_replication_diagnostics(self):
        self.a.fail_start = True
        with self.assertRaisesRegex(RuntimeError, "authentication"):
            self.flow.run()
        diagnostic_events = [e for e in self.events if e[:2] == ("journal", "replication_diagnostics")]
        self.assertEqual(len(diagnostic_events), 1)
        self.assertEqual(diagnostic_events[0][2]["operation"], "reset/configure/start/wait")
        self.assertIn("show_replica_status", diagnostic_events[0][2]["snapshot"])
        self.assertEqual((self.a.sro, self.b.sro), (1, 1))


class ConsistencyTests(unittest.TestCase):
    def test_reset_guard_rejects_unapplied_relay_gtids(self):
        db = Mock()
        db.scalar.side_effect = ["executed:1-8", "executed:9"]
        with self.assertRaisesRegex(m.SafetyError, "unapplied relay GTIDs"):
            m.require_no_unapplied_relay_gtids(db, {"Retrieved_Gtid_Set": "executed:1-9"})

    def test_replication_diagnostics_redacts_passwords_and_keeps_queryable_error(self):
        db = Mock()
        error_log_queries = []

        def rows(sql, params=()):
            if "performance_schema.error_log" in sql:
                error_log_queries.append(sql)
                return [{"ERROR_CODE": "MY-013124", "DATA": "auth secret-value"}]
            if sql == "SHOW REPLICA STATUS":
                return [{"Last_SQL_Errno": 1872, "Last_SQL_Error": "applier metadata failed"}]
            return []

        db.rows.side_effect = rows
        result = m.replication_diagnostics(db, ["secret-value"])
        self.assertEqual(result["show_replica_status"][0]["Last_SQL_Errno"], 1872)
        self.assertEqual(result["recent_replication_error_log"][0]["DATA"], "auth [REDACTED]")
        self.assertIn("DATA LIKE '%%relay%%'", error_log_queries[0])
        self.assertIn("DATA LIKE '%%applier%%'", error_log_queries[0])

    def test_proxy_active_rule_count_accepts_text_zero(self):
        proxy = Mock()
        proxy.scalar.return_value = "0"
        m.no_active_query_rules(proxy)

    def test_proxy_active_rules_still_stop_preflight(self):
        proxy = Mock()
        proxy.scalar.return_value = "2"
        with self.assertRaisesRegex(m.SafetyError, "2 active query rules"):
            m.no_active_query_rules(proxy)

    def test_existing_certificate_verification_is_not_silently_downgraded(self):
        db = Mock()
        db.rows.return_value = [{**replication_status("other", False), "Source_SSL_Verify_Server_Cert": "Yes"}]
        with self.assertRaisesRegex(m.SafetyError, "TLS verification"):
            m.no_incoming_replication(db)

    def test_equal_gtid_does_not_bypass_row_checksum_mismatch(self):
        a, b = Mock(), Mock()
        a.rows.return_value = b.rows.return_value = [{"collation": "same"}]
        with patch.object(m, "fingerprint", side_effect=[{"orders": {"rows": 20, "checksum": 1}}, {"orders": {"rows": 20, "checksum": 2}}]):
            with self.assertRaisesRegex(m.SafetyError, "orders"):
                m.compare_data(a, b, "stockspoon")

    def test_schema_mismatch_rejected_before_checksum(self):
        a, b = Mock(), Mock()
        a.rows.return_value = ["a"]
        b.rows.return_value = ["b"]
        with self.assertRaisesRegex(m.SafetyError, "collation"):
            m.compare_data(a, b, "stockspoon")

    def test_null_checksum_is_not_accepted(self):
        db = Mock()
        db.rows.side_effect = [{"Create Table": "CREATE TABLE t(a int)"}], [{"Checksum": None}]
        with patch.object(m, "inventory", return_value=["t"]):
            with self.assertRaisesRegex(m.SafetyError, "No checksum"):
                m.fingerprint(db, "stockspoon")

    def test_active_incoming_channel_on_primary_is_rejected(self):
        db = Mock()
        db.rows.return_value = [replication_status("other")]
        with self.assertRaisesRegex(m.SafetyError, "active"):
            m.no_incoming_replication(db)

    def test_two_writers_even_when_monitor_looks_good_are_rejected(self):
        cfg = {n: dict(server_host=n, server_port=3306) for n in ("source", "target")}
        proxy = Mock()
        proxy.rows.return_value = [dict(hostgroup_id=10, hostname=n, port=3306, status="ONLINE") for n in cfg]
        flow = m.Switch(cfg, {"source": Mock(), "target": Mock(), "proxy_admin": proxy}, Mock(), {}, Mock())
        with self.assertRaises(m.SafetyError) as raised:
            flow.routes("source")
        self.assertIn("Unexpected/offline ProxySQL hostgroup membership", str(raised.exception))
        self.assertIn('"writer_expected": "source"', str(raised.exception))
        self.assertIn('"actual": [[10, "source", 3306, "ONLINE"], [10, "target", 3306, "ONLINE"]]',
                      str(raised.exception))

    def test_both_fenced_accepts_stale_offline_hard_old_writer_row(self):
        cfg = {n: dict(server_host=n, server_port=3306) for n in ("source", "target")}
        proxy = Mock()
        proxy.rows.return_value = [
            dict(hostgroup_id=10, hostname="source", port=3306, status="OFFLINE_HARD"),
            dict(hostgroup_id=20, hostname="source", port=3306, status="ONLINE"),
            dict(hostgroup_id=20, hostname="target", port=3306, status="ONLINE"),
        ]
        flow = m.Switch(cfg, {"source": Mock(), "target": Mock(), "proxy_admin": proxy}, Mock(), {}, Mock())
        flow.monitor = Mock(side_effect=[
            dict(time_start_us=101, read_only=1, error=None),
            dict(time_start_us=101, read_only=1, error=None),
        ])

        flow.routes(None)

    def test_promoted_route_accepts_stale_offline_hard_old_writer_row(self):
        cfg = {n: dict(server_host=n, server_port=3306) for n in ("source", "target")}
        proxy = Mock()
        proxy.rows.return_value = [
            dict(hostgroup_id=10, hostname="source", port=3306, status="OFFLINE_HARD"),
            dict(hostgroup_id=20, hostname="source", port=3306, status="ONLINE"),
            dict(hostgroup_id=10, hostname="target", port=3306, status="ONLINE"),
        ]
        flow = m.Switch(cfg, {"source": Mock(), "target": Mock(), "proxy_admin": proxy}, Mock(), {}, Mock())
        flow.monitor = Mock(side_effect=[
            dict(time_start_us=101, read_only=1, error=None),
            dict(time_start_us=101, read_only=0, error=None),
        ])

        flow.routes("target")

    def test_unknown_offline_hard_row_is_rejected(self):
        cfg = {n: dict(server_host=n, server_port=3306) for n in ("source", "target")}
        proxy = Mock()
        proxy.rows.return_value = [
            dict(hostgroup_id=20, hostname="source", port=3306, status="ONLINE"),
            dict(hostgroup_id=20, hostname="target", port=3306, status="ONLINE"),
            dict(hostgroup_id=10, hostname="unexpected", port=3306, status="OFFLINE_HARD"),
        ]
        flow = m.Switch(cfg, {"source": Mock(), "target": Mock(), "proxy_admin": proxy}, Mock(), {}, Mock())

        with self.assertRaisesRegex(m.SafetyError, "Unexpected/offline ProxySQL hostgroup membership"):
            flow.routes(None)

    def test_stale_monitor_observation_cannot_complete_cutover(self):
        cfg = {n: dict(server_host=n, server_port=3306) for n in ("source", "target")}
        proxy = Mock()
        proxy.rows.return_value = [dict(hostgroup_id=10 if n == "target" else 20, hostname=n, port=3306, status="ONLINE") for n in cfg]
        flow = m.Switch(cfg, {"source": Mock(), "target": Mock(), "proxy_admin": proxy}, Mock(), {}, Mock())
        flow.monitor_baseline = dict(source=100, target=100)
        flow.monitor = Mock(return_value=dict(time_start_us=99, read_only=1, error=None))
        with self.assertRaisesRegex(m.SafetyError, "fresh"):
            flow.routes("target")

    def test_replication_filter_is_rejected(self):
        db = Mock()
        db.rows.return_value = [{**replication_status("source"), "Replicate_Ignore_Table": "stockspoon.orders"}]
        with self.assertRaisesRegex(m.SafetyError, "filter"):
            m.replica(db, "source")


class CaptureTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.journal = m.Journal(Path(temporary.name) / "capture", "capture")
        self.flow = Mock(journal=self.journal)
        self.cfg = dict(schema="stockspoon", source=dict(host="127.0.0.1", port=13306,
                                                       user="root", password_env="PASSWORD"))

    def dump_result(self, metadata, complete=True):
        def run(*args, **kwargs):
            dump = self.journal.directory / "dump"
            dump.mkdir()
            (dump / "@.json").write_text(json.dumps(metadata))
            if complete:
                (dump / "@.done.json").write_text("{}")
            self.assertEqual(kwargs["input"], "private-test-password\n")
            self.assertNotIn("private-test-password", " ".join(args[0]))
            return Mock(returncode=0)
        return run

    def test_missing_binlog_boundary_cannot_become_successful_capture(self):
        with patch.object(m.subprocess, "run", side_effect=self.dump_result(dict(gtidExecuted=OLD, binlogFile="", binlogPosition=0))):
            with self.assertRaisesRegex(m.SafetyError, "boundary"):
                m.capture(self.flow, self.cfg, {"PASSWORD": "private-test-password"})
        self.assertNotEqual(self.journal.state["status"], "complete")

    def test_partial_dump_is_rejected_even_if_process_succeeded(self):
        with patch.object(m.subprocess, "run", side_effect=self.dump_result({}, complete=False)):
            with self.assertRaisesRegex(m.SafetyError, "Dump failed"):
                m.capture(self.flow, self.cfg, {"PASSWORD": "private-test-password"})

    def test_completed_dump_has_fingerprints_and_private_durable_record(self):
        metadata = dict(gtidExecuted=OLD, binlogFile="binlog.000011", binlogPosition=800)
        with patch.object(m.subprocess, "run", side_effect=self.dump_result(metadata)):
            m.capture(self.flow, self.cfg, {"PASSWORD": "private-test-password"})
        path = self.journal.directory / "state.json"
        saved = json.loads(path.read_text())
        self.assertEqual(saved["status"], "complete")
        self.assertEqual(set(saved["dump_sha256"]), {"@.json", "@.done.json"})
        self.assertEqual(saved["dump_metadata"], metadata)
        self.assertEqual(path.stat().st_mode & 0o777, 0o600)
        self.assertNotIn("private-test-password", path.read_text())
        with self.assertRaises(FileExistsError):
            m.Journal(self.journal.directory, "capture")


if __name__ == "__main__":
    unittest.main()
