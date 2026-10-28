import importlib.util
import json
from pathlib import Path
import re
import unittest

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location("test_publisher_deploy", ROOT / "scripts/render-deploy.py")
deploy = importlib.util.module_from_spec(spec)
spec.loader.exec_module(deploy)


class TestPublisherCollectionTest(unittest.TestCase):
    def destination(self, environment="prod"):
        return {
            "environment": environment,
            "cluster": "stockspoon-v1-ai" if environment == "prod" else "stockspoon-v2-dev",
            "loki_push_url": "http://10.0.11.236:3100/loki/api/v1/push",
            "prometheus_write_url": "http://10.0.11.236:9090/api/v1/write",
        }

    def test_test_collection_is_explicit_and_keeps_real_source_separate(self):
        for environment in ["dev", "prod"]:
            target = environment + "-ai-agent"
            original = deploy.deployment_files(target, self.destination(environment))
            enabled = deploy.deployment_files(target, self.destination(environment), test_streamer=True)
            self.assertNotIn(b'test_streamer_metrics', original['ai-agent/config.alloy'])
            added = (ROOT / 'ai-agent/test-streamer.alloy').read_bytes()
            self.assertEqual(enabled['ai-agent/config.alloy'], original['ai-agent/config.alloy'] + added)
            for name in original.keys() - {'ai-agent/config.alloy'}:
                self.assertEqual(original[name], enabled[name])
            self.assertIn(b'127.0.0.1:9103', added)
            self.assertIn(b'source = "test-streamer"', added)
            self.assertIn(b'mock-market-streamer;publisher;test-streamer', added)
            self.assertNotIn(b'replacement = "market-streamer-metrics"', added)
        with self.assertRaises(ValueError):
            deploy.deployment_files('server', {}, test_streamer=True)
        with self.assertRaises(ValueError):
            deploy.deployment_files('prod-ai-agent', self.destination(), test_streamer=True, streamer_metrics_port=9103)

    def test_test_publisher_allowlist_and_dashboard_preserve_source_identity(self):
        config = (ROOT / 'ai-agent/test-streamer.alloy').read_text()
        pattern = next(p for p in re.findall(r'regex = "([^"]+)"', config) if p.startswith('test_streamer_'))
        for name in ['test_streamer_published_events_total', 'test_streamer_publish_unconfirmed_events_total',
                     'test_streamer_publish_duration_seconds_bucket', 'test_streamer_publish_age_seconds']:
            self.assertIsNotNone(re.fullmatch(pattern, name), name)
        self.assertIsNone(re.fullmatch(pattern, 'market_streamer_market_events_received_total'))
        dashboard = json.loads((ROOT / 'config/grafana/dashboards/prod/market-fis.json').read_text())
        self.assertEqual(dashboard['uid'], 'stockspoon-market-fis')
        ids = [p['id'] for p in dashboard['panels']]
        self.assertEqual(len(ids), len(set(ids)))
        expressions = [t.get('expr', '') for p in dashboard['panels'] for t in p['targets']]
        for expression in expressions:
            self.assertNotIn('or vector(0)', expression)
            if 'test_streamer_' in expression:
                self.assertIn('source="test-streamer"', expression)
                self.assertIn('service_name="test-streamer"', expression)
            if 'market_http_' in expression:
                self.assertIn('service_name="market-http"', expression)
                self.assertIn('${task:regex}', expression)
        self.assertNotIn('market_streamer_market_events_received', json.dumps(dashboard))


if __name__ == '__main__':
    unittest.main()
