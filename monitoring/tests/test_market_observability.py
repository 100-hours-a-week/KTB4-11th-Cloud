import copy
import importlib.util
import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import Mock, patch

ROOT = Path(__file__).resolve().parents[1]


def module(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    result = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(result)
    return result


exporter = module("market_exporter", ROOT / "market-observability/exporter.py")
migration = module("market_migration", ROOT / "scripts/prepare-market-observability.py")


class MarketObservabilityTest(unittest.TestCase):
    def client(self, running=1):
        client = Mock()
        client.describe_services.return_value = {"services": [{
            "serviceArn": exporter.SERVICE_ARN, "status": "ACTIVE", "desiredCount": 2,
            "runningCount": running, "pendingCount": 0}]}
        arn = f"arn:aws:ecs:{exporter.REGION}:{exporter.ACCOUNT}:task/{exporter.CLUSTER}/" + "a" * 32
        client.get_paginator.return_value.paginate.return_value = [{"taskArns": [arn] if running else []}]
        client.describe_tasks.return_value = {"tasks": [{
            "group": "service:" + exporter.SERVICE, "taskArn": arn, "lastStatus": "RUNNING",
            "cpu": "1024", "memory": "2048"}]}
        return client

    def test_ecs_metadata_does_not_guess_capacity_or_call_cloudwatch(self):
        client = self.client()
        output = exporter.collect(client)
        self.assertIn('stockspoon_ecs_task_cpu_reserved_cores{', output)
        self.assertIn(' 2147483648.0\n', output)
        self.assertEqual({call[0].split('(')[0].split('.')[0] for call in client.mock_calls},
                         {"describe_services", "get_paginator", "describe_tasks"})
        client.describe_tasks.return_value["tasks"][0]["cpu"] = ""
        with self.assertRaisesRegex(ValueError, "reservations"):
            exporter.collect(client)

    def test_empty_service_reports_real_zero_not_missing(self):
        client = self.client(running=0)
        output = exporter.collect(client)
        self.assertIn('stockspoon_ecs_service_running_tasks{', output)
        self.assertNotIn('stockspoon_ecs_task_cpu_reserved_cores{', output)
        client.describe_tasks.assert_not_called()

    def test_wrong_service_and_partial_tasks_are_rejected(self):
        client = self.client()
        client.describe_tasks.return_value["tasks"][0]["group"] = "service:backend"
        with self.assertRaisesRegex(ValueError, "outside"):
            exporter.collect(client)
        client = self.client()
        client.describe_tasks.return_value = {"tasks": [], "failures": [{"reason": "MISSING"}]}
        with self.assertRaisesRegex(ValueError, "Incomplete"):
            exporter.collect(client)

    def test_failure_and_staleness_never_publish_old_counts_as_healthy(self):
        cache = exporter.Cache()
        client = self.client()
        with patch.object(exporter.time, "time", return_value=100):
            cache.update(client)
            self.assertIn('stockspoon_ecs_service_running_tasks{', cache.render())
        with patch.object(exporter.time, "time", return_value=176):
            self.assertNotIn('stockspoon_ecs_service_running_tasks{', cache.render())
        client.describe_services.side_effect = RuntimeError("sensitive response")
        with patch("builtins.print") as print_mock:
            cache.update(client)
            self.assertNotIn("sensitive response", str(print_mock.call_args))
        self.assertNotIn('stockspoon_ecs_service_running_tasks{', cache.render())

    def test_switch_preserves_other_services_and_existing_alert_identity(self):
        source = json.loads((ROOT / "config/grafana/provisioning/alerting/prod-services-rules.json").read_text())
        result = migration.alerts(source)
        self.assertEqual(result["groups"][1:], source["groups"][1:])
        original = source["groups"][0]["rules"]
        converted = result["groups"][0]["rules"]
        self.assertEqual([r["uid"] for r in converted[:len(original)]], [r["uid"] for r in original])
        for before, after in zip(original, converted):
            self.assertEqual(before["labels"], after["labels"])
            self.assertEqual(before["isPaused"], after["isPaused"])
            self.assertEqual(before["data"][-1], after["data"][-1])
        for rule in converted:
            self.assertNotEqual(rule["data"][0]["datasourceUid"], "cloudwatch")
            if rule["data"][0]["datasourceUid"] == "prometheus":
                self.assertIn('market-http', rule["data"][0]["model"]["expr"])
        self.assertEqual(original, source["groups"][0]["rules"])
        self.assertEqual(migration.alerts(result), result)

    def test_dashboard_is_market_only_and_keeps_bookmarks_and_task_filter(self):
        source = json.loads((ROOT / "config/grafana/dashboards/prod/ecs-sse.json").read_text())
        result = migration.dashboard(source)
        self.assertEqual(result["uid"], source["uid"])
        self.assertEqual(result["templating"]["list"], [v for v in source["templating"]["list"] if v["name"] == "task"])
        for panel in result["panels"]:
            for target in panel.get("targets", []):
                self.assertNotIn('$service', json.dumps(target))
                self.assertNotEqual(target.get("datasource", {}).get("uid"), "cloudwatch")
            if panel["id"] in [1, 7, 8] or panel["id"] >= 20:
                self.assertEqual(panel, next(p for p in source["panels"] if p["id"] == panel["id"]))

    def test_two_phase_bundle_does_not_modify_live_or_source_configuration(self):
        source = ROOT / "config/grafana/dashboards/prod/ecs-sse.json"
        before = source.read_bytes()
        with tempfile.TemporaryDirectory() as tmp:
            collector = Path(tmp) / "collector"
            migration.prepare(collector)
            self.assertFalse((collector / "grafana").exists())
            self.assertIn('market-ecs-exporter:9190', (collector / "prometheus.yaml").read_text())
            switched = Path(tmp) / "switch"
            migration.prepare(switched, switch=True)
            self.assertTrue((switched / "grafana/dashboards/prod/ecs-sse.json").exists())
            with self.assertRaises(ValueError):
                migration.prepare(switched)
        self.assertEqual(source.read_bytes(), before)


if __name__ == "__main__":
    unittest.main()
