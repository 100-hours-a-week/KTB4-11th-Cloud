import importlib.util
import json
import unittest
from pathlib import Path

spec = importlib.util.spec_from_file_location(
    "collector", Path(__file__).resolve().parents[1] / "ecs_experiment_cloudwatch.py"
)
collector = importlib.util.module_from_spec(spec)
spec.loader.exec_module(collector)


class ClientMetricsTest(unittest.TestCase):
    def point(self, metric, value):
        return {
            "type": "Point", "metric": metric,
            "data": {"time": "2026-10-16T12:00:00.123Z", "value": value},
        }

    def test_latency_preserves_raw_sample_and_timestamp(self):
        event = collector.point_event(self.point("http_req_duration", 12.5), "backend", "migration", "run-1")
        data = json.loads(event["message"])
        self.assertEqual(event["timestamp"], 1792152000123)
        self.assertEqual(data["RequestDurationMs"], 12.5)
        self.assertEqual(data["TestId"], "run-1")
        self.assertEqual(data["_aws"]["CloudWatchMetrics"][0]["Dimensions"], [["ServiceName", "Scenario"]])

    def test_zero_failures_and_reconnect_counts_are_not_dropped(self):
        for metric, field, value in [("http_req_failed", "Failures", 0), ("sse_reconnects", "SSEReconnects", 2)]:
            event = collector.point_event(self.point(metric, value), "market-http", "fault", "run-1")
            self.assertEqual(json.loads(event["message"])[field], value)

    def test_metadata_and_unknown_metrics_are_ignored(self):
        self.assertIsNone(collector.point_event({"type": "Metric"}, "backend", "scaling", "run-1"))
        self.assertIsNone(collector.point_event(self.point("vus", 10), "backend", "scaling", "run-1"))

    def test_invalid_samples_are_rejected(self):
        for value in [float("nan"), float("inf"), -1, "12"]:
            with self.assertRaises(ValueError):
                collector.point_event(self.point("http_req_duration", value), "backend", "scaling", "run-1")
        point = self.point("http_req_duration", 10)
        point["data"]["time"] = "2026-10-16T12:00:00"
        with self.assertRaises(ValueError):
            collector.point_event(point, "backend", "scaling", "run-1")


if __name__ == "__main__":
    unittest.main()
