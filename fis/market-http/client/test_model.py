import argparse
import datetime as dt
import json
import tempfile
import unittest
from pathlib import Path

from model import State, allocation, make_plan, report, validate_plan
from fis import mark


def event(kind, at, client="1", **extra):
    return {"kind": kind, "at_ms": at, "client_id": client, **extra}


class MeasurementTests(unittest.TestCase):
    def test_scope_and_group_allocation(self):
        self.assertEqual(sum(allocation(500).values()), 500)
        self.assertEqual(allocation(500)["orderbooks"], 96)
        with tempfile.TemporaryDirectory() as folder:
            codes = Path(folder) / "codes.txt"
            codes.write_text("\n".join(f"{i:06}" for i in range(14)))
            args = argparse.Namespace(connections=500, base_url="https://stock-spoon.com/market",
                                      price_codes=str(codes), orderbook_codes=str(codes),
                                      ramp=120, baseline=600, fault_wait=300, observe=600, mode="fault")
            plan = make_plan(args)
            validate_plan(plan)
            plan["base_url"] = "https://example.com/market"
            with self.assertRaises(ValueError):
                validate_plan(plan)

    def test_reconnection_and_first_update_are_separate(self):
        rows = [event("connected", 100), event("disconnected", 1000, outage_id=1, last_update_ms=900),
                event("connected", 2000), event("reconnected", 2000, outage_id=1),
                event("recovery_update", 4000, outage_id=1, source_age_ms=250)]
        result = report(rows, [{"event": "fault-start", "at_ms": 950}], 5000, "observation_window_ended")
        self.assertEqual(result["reconnection"]["p95_ms"], 1000)
        self.assertEqual(result["first_advancing_data"]["p95_ms"], 3000)
        self.assertEqual(result["data_gap"]["max_ms"], 3100)
        self.assertIn("NOT_MEASURED", result["latest_quote_recovery"])

    def test_unrecovered_episode_is_censored_not_discarded(self):
        rows = [event("connected", 100), event("connected", 100, client="2"),
                event("disconnected", 1000, outage_id=1),
                event("disconnected", 1000, client="2", outage_id=1),
                event("reconnected", 2000, outage_id=1),
                event("recovery_update", 3000, outage_id=1, source_age_ms=100)]
        result = report(rows, [{"event": "fault-start", "at_ms": 900}], 10000, "observation_window_ended")
        self.assertEqual(result["outcome"], "WINDOW_ENDED")
        self.assertFalse(result["whole_population_percentiles_available"])
        self.assertEqual(result["unrecovered"][0]["unrecovered_for_at_least_ms"], 9000)
        self.assertEqual(result["affected_clients"], 2)

    def test_shutdown_events_and_initial_errors_are_not_fault_cohort(self):
        rows = [event("initial_rest_error", 100), event("connected", 1000),
                event("disconnected", 8000, outage_id=1),
                event("disconnected", 9000, outage_id=2)]
        result = report(rows, [{"event": "fault-start", "at_ms": 2000}], 8000, "operator_stop")
        self.assertEqual(result["disconnect_episodes"], 0)

    def test_failed_reconnect_does_not_count_as_connected(self):
        state = State()
        state.feed(event("connected", 100))
        state.feed(event("disconnected", 200, outage_id=1))
        state.feed(event("connected", 300))
        state.feed(event("session_ended", 400, outage_id=1))
        self.assertEqual(state.snapshot(500)["connected_clients"], 0)

    def test_advancing_but_stale_data_is_not_fresh_recovery(self):
        rows = [event("connected", 100), event("disconnected", 1000, outage_id=1),
                event("reconnected", 2000, outage_id=1),
                event("recovery_update", 2500, outage_id=1, source_age_ms=20000)]
        result = report(rows, [{"event": "fault-start", "at_ms": 900}], 10000, "observation_window_ended")
        self.assertEqual(result["advancing_data_recovery_rate"], 1)
        self.assertEqual(result["fresh_data_recovery_rate"], 0)
        self.assertEqual(result["outcome"], "MEASURED")
        self.assertTrue(result["freshness_reference_only"])
        self.assertEqual(len(result["fresh_data_unrecovered"]), 1)
        rows.append(event("fresh_recovery", 4000, outage_id=1, max_source_age_ms=200))
        result = report(rows, [{"event": "fault-start", "at_ms": 900}], 10000, "observation_window_ended")
        self.assertEqual(result["fresh_data"]["p95_ms"], 3000)
        self.assertEqual(result["fault_to_fresh_data"]["p95_ms"], 3100)
        self.assertEqual(result["outcome"], "MEASURED")

    def test_silent_connected_client_and_stale_snapshot_expire(self):
        state = State()
        state.feed(event("snapshot", 1000, post_initial_updates=1, last_update_ms=1000,
                         oldest_advancing_source_ms=900, newest_advancing_source_ms=900))
        self.assertEqual(state.snapshot(6000)["clients_with_fresh_data"], 1)
        self.assertEqual(state.snapshot(17000)["clients_with_fresh_data"], 0)
        state.feed(event("snapshot", 18000, post_initial_updates=2, last_update_ms=18000,
                         oldest_advancing_source_ms=1000, newest_advancing_source_ms=1000))
        self.assertEqual(state.snapshot(18000)["connected_without_fresh_data"], 1)

    def test_mark_after_actual_fault_accepts_pre_fault_baseline_evidence(self):
        with tempfile.TemporaryDirectory() as folder:
            path = Path(folder)
            # Actual fault may already have disconnected clients before the operator records its timestamp.
            (path / "status.json").write_text(json.dumps({"running": True, "started_at_ms": 100,
                "baseline_ready_at_ms": 1000, "ready_for_manual_fault": False}))
            (path / "plan.json").write_text("{}")
            args = argparse.Namespace(run=str(path), at=dt.datetime.fromtimestamp(2, dt.timezone.utc).isoformat(),
                                      event="fault-start", note="", experiment_id="EXPTEST")
            mark(args)
            self.assertEqual(json.loads((path / "markers.jsonl").read_text())["at_ms"], 2000)
            with self.assertRaises(ValueError):
                mark(args)

    def test_exploratory_baseline_records_transient_disconnects_without_resetting_observation(self):
        with tempfile.TemporaryDirectory() as folder:
            path = Path(folder)
            (path / "status.json").write_text(json.dumps({"running": True, "started_at_ms": 100,
                                                        "ready_for_manual_fault": False}))
            (path / "plan.json").write_text(json.dumps({"connections": 900, "baseline_seconds": 300}))
            rows = [{"at_ms": 1000, "connected_clients": 900},
                    {"at_ms": 200000, "connected_clients": 899},
                    {"at_ms": 301000, "connected_clients": 900}]
            (path / "observations.jsonl").write_text("".join(json.dumps(r) + "\n" for r in rows))
            args = argparse.Namespace(run=str(path), at=dt.datetime.fromtimestamp(300, dt.timezone.utc).isoformat(),
                                      event="fault-start", note="", experiment_id="EXPTEST")
            with self.assertRaises(ValueError):
                mark(args)
            args.at = dt.datetime.fromtimestamp(302, dt.timezone.utc).isoformat()
            mark(args)
            recorded = json.loads((path / "markers.jsonl").read_text())
            self.assertIn("baseline_evidence", recorded)


if __name__ == "__main__":
    unittest.main()
