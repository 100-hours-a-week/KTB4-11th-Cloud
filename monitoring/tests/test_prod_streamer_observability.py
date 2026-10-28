import base64
import importlib.util
from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location(
    "prepare_streamer", ROOT / "scripts/prepare-prod-streamer-observability.py"
)
prepare = importlib.util.module_from_spec(spec)
spec.loader.exec_module(prepare)
deploy_spec = importlib.util.spec_from_file_location("render_ai_deploy", ROOT / "scripts/render-deploy.py")
deploy = importlib.util.module_from_spec(deploy_spec)
deploy_spec.loader.exec_module(deploy)


class StreamerPatchTest(unittest.TestCase):
    def test_production_agent_redeploy_keeps_streamer_scraping(self):
        files = deploy.deployment_files("prod-ai-agent", {
            "environment": "prod", "cluster": "stockspoon-v1-ai",
            "loki_push_url": "http://10.0.11.236:3100/loki/api/v1/push",
            "prometheus_write_url": "http://10.0.11.236:9090/api/v1/write",
        })
        config = files["ai-agent/config.alloy"].decode()
        self.assertIn('127.0.0.1:9102', config)
        self.assertIn('market-streamer-metrics', config)
        self.assertNotIn('prometheus.scrape "market_metrics"', config)

    def test_patch_is_pinned_to_ai_and_enables_private_metrics_and_traces(self):
        payload = prepare.payload("http://10.0.11.236:4318", "a" * 64)
        self.assertEqual(payload["InstanceIds"], ["i-04ab95c711878616c"])
        commands = payload["Parameters"]["commands"]
        override = base64.b64decode(commands[2].split("'")[3]).decode()
        self.assertIn('127.0.0.1:9102:9102', override)
        self.assertIn('OTEL_SDK_DISABLED: "false"', override)
        self.assertIn('http://10.0.11.236:4318', override)
        installer = (ROOT / "scripts/deploy/prod-streamer-observability.sh").read_text()
        self.assertIn('run --rm --no-deps --service-ports -T market-streamer', installer)
        self.assertNotIn('compose up', installer)
        self.assertNotIn('systemctl restart ktb-market-streamer', installer)
        self.assertIn('trap rollback ERR', installer)

    def test_public_or_wrong_protocol_endpoints_are_rejected(self):
        for endpoint in ["http://8.8.8.8:4318", "https://10.0.0.1:4318",
                         "http://10.0.0.1:9090", "http://user:pass@10.0.0.1:4318"]:
            with self.subTest(endpoint=endpoint), self.assertRaises(ValueError):
                prepare.payload(endpoint, "a" * 64)


if __name__ == "__main__":
    unittest.main()
