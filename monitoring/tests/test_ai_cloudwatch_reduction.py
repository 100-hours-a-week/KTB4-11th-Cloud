import copy
import importlib.util
import json
from pathlib import Path
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location("ai_reduction", ROOT / "scripts/prepare-ai-cloudwatch-reduction.py")
reduction = importlib.util.module_from_spec(spec)
spec.loader.exec_module(reduction)


class AiCloudWatchReductionTest(unittest.TestCase):
    def current(self):
        config = json.loads((ROOT.parent / "ai-server/infra/config/cloudwatch-agent.json").read_text())
        config["metrics"]["metrics_collected"].update({
            "net": {"measurement": ["bytes_sent", "bytes_recv"], "resources": ["*"]},
            "diskio": {"resources": ["*"]}, "processes": {}, "swap": {}, "netstat": {},
        })
        config["metrics"]["metrics_collected"]["cpu"]["resources"] = ["*"]
        config["agent"]["custom_existing_setting"] = "preserve"
        return config

    def test_removes_interface_and_core_cardinality_but_keeps_alarm_metrics_and_logs(self):
        current = self.current()
        original = copy.deepcopy(current)
        result = reduction.reduce_config(current)
        self.assertEqual(current, original)
        self.assertEqual(result["logs"], current["logs"])
        self.assertEqual(result["agent"], current["agent"])
        self.assertEqual(result["metrics"]["append_dimensions"], current["metrics"]["append_dimensions"])
        collected = result["metrics"]["metrics_collected"]
        self.assertEqual(set(collected), {"cpu", "mem", "disk"})
        self.assertNotIn("resources", collected["cpu"])
        self.assertTrue(collected["cpu"]["totalcpu"])
        self.assertEqual(sum(len(x["measurement"]) for x in collected.values()), 4)
        self.assertEqual(collected["disk"]["resources"], ["/"])
        self.assertEqual(reduction.reduce_config(result), result)

    def test_rejects_non_ai_namespace_and_unknown_rollups(self):
        current = self.current()
        current["metrics"]["namespace"] = "CWAgent"
        with self.assertRaises(ValueError):
            reduction.reduce_config(current)
        current = self.current()
        current["metrics"]["aggregation_dimensions"] = [["InstanceId"]]
        with self.assertRaises(ValueError):
            reduction.reduce_config(current)

    def test_live_apply_rejects_wrong_instance_before_reading_or_writing_config(self):
        with patch.object(reduction.os, "geteuid", return_value=0), \
             patch.object(reduction, "instance_id", return_value="i-wrong"), \
             patch.object(reduction.subprocess, "run") as run:
            with self.assertRaises(ValueError):
                reduction.apply_on_ai("i-04ab95c711878616c")
            run.assert_not_called()

    def test_ai_metrics_missing_rule_does_not_depend_on_ecs_cluster(self):
        doc = json.loads((ROOT / "config/grafana/provisioning/alerting/rules.json").read_text())
        rule = next(r for g in doc["groups"] for r in g["rules"]
                    if r["uid"] == "stockspoon-prod-ai-metrics-missing")
        expr = rule["data"][0]["model"]["expr"]
        self.assertIn('cluster="stockspoon-v1-ai"', expr)
        self.assertIn('host_role="ai"', expr)
        self.assertNotIn("stockspoon-v2-prod-cluster", expr)
        self.assertEqual(rule["labels"]["host_role"], "ai")
        self.assertEqual(rule["noDataState"], "Alerting")


if __name__ == "__main__":
    unittest.main()
