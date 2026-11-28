import contextlib
import importlib.util
import io
import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import Mock

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location("db_fis_observer", ROOT / "db-fis/observer.py")
observer = importlib.util.module_from_spec(spec)
spec.loader.exec_module(observer)


class DBFISObserverTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.now = 1000.0
        self.logs = Mock()
        self.logs.filter_log_events.return_value = {"events": []}
        self.query = Mock(return_value=[{"metric": {"instance": "proxy:6070", "endpoint": "10.0.1.1:3306"}, "value": [1000, "999"]}])
        self.observer = observer.Observer(self.temporary.name, self.logs, self.query, clock=lambda: self.now)

    def update(self):
        with contextlib.redirect_stdout(io.StringIO()):
            self.observer.update()

    def entry(self, name, message, timestamp=999000):
        return {"eventId": name, "message": message, "timestamp": timestamp}

    def test_auth_error_never_becomes_successful_promotion_and_secret_is_not_logged(self):
        self.logs.filter_log_events.return_value = {"events": [self.entry("a",
            'Server 10.0.1.1:3306 state transition from Suspect changed to: ErrorAuth password=DO_NOT_COPY')]}
        self.update()
        output = self.observer.render()
        self.assertIn('state="ErrorAuth"', output)
        self.assertNotIn('event="repman_switch_complete"', output)
        self.assertNotIn("DO_NOT_COPY", (Path(self.temporary.name) / "events.jsonl").read_text())
        self.assertNotIn("DO_NOT_COPY", (Path(self.temporary.name) / "state.json").read_text())

    def test_first_writer_snapshot_is_not_a_transition_but_changed_writer_is_persisted(self):
        self.update()
        self.assertNotIn('event="proxysql_writer_observed"', self.observer.render())
        self.now = 1005
        self.query.return_value = [{"metric": {"instance": "new-proxy:6070", "endpoint": "10.0.2.1:3306"}, "value": [1005, "1004"]}]
        self.update()
        event = self.observer.state["events"]["proxysql_writer_observed|10.0.2.1:3306"]
        self.assertEqual(event["source_timestamp_seconds"], 1004)
        self.assertEqual(event["previous_sample_timestamp_seconds"], 999)
        self.assertEqual(event["timing"], "sampled")
        reloaded = observer.Observer(self.temporary.name)
        self.assertEqual(reloaded.state["writer"]["endpoint"], "10.0.2.1:3306")

    def test_cloudwatch_source_time_and_delivery_time_are_separate_and_duplicates_ignored(self):
        at = "1970-01-01T00:16:38Z"
        self.logs.filter_log_events.return_value = {"events": [self.entry("b",
            f'time="{at}" level=info msg="Master switch on 10.0.2.1:3306 complete"')]}
        self.update()
        self.update()
        events = [json.loads(line) for line in (Path(self.temporary.name) / "events.jsonl").read_text().splitlines()]
        self.assertEqual(len(events), 1)
        self.assertEqual(events[0]["source_timestamp_seconds"], 998)
        self.assertEqual(events[0]["cloudwatch_timestamp_seconds"], 999)
        self.assertEqual(events[0]["observed_at_seconds"], 1000)

    def test_pagination_error_does_not_advance_cursor_or_publish_healthy(self):
        self.logs.filter_log_events.side_effect = RuntimeError("SECRET")
        self.update()
        self.assertEqual(self.observer.state["cursor_ms"], 0)
        self.assertIn('source="repman_logs"} 0.0', self.observer.render())
        self.assertNotIn("SECRET", self.observer.render())

    def test_no_stale_writer_snapshot_is_used_to_invent_a_transition(self):
        self.update()
        self.now = 1050
        self.query.return_value = [{"metric": {"endpoint": "10.0.2.1:3306"}, "value": [1050, "1001"]}]
        self.update()
        self.assertIn('source="proxysql"} 0.0', self.observer.render())
        self.assertNotIn('event="proxysql_writer_observed"', self.observer.render())

    def test_failed_node_is_not_assumed_to_be_primary(self):
        value = observer.classify("Server 10.0.2.1:3306 state transition from Suspect changed to: Failed")
        self.logs.filter_log_events.return_value = {"events": [self.entry("c", "Server 10.0.2.1:3306 state transition from Suspect changed to: Failed")]}
        self.update()
        self.assertIn("repman_node_failed|10.0.2.1:3306", self.observer.state["events"])
        self.assertEqual(value["state"], "Failed")
        self.assertNotIn("repman_primary_failure_observed", self.observer.render())


if __name__ == "__main__":
    unittest.main()
