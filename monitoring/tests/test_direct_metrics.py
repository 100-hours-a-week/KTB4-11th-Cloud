from contextlib import redirect_stdout
import importlib.util
import io
import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('metrics_deploy', ROOT / 'scripts/render-deploy.py')
deploy = importlib.util.module_from_spec(spec)
spec.loader.exec_module(deploy)


class DirectMetricsTest(unittest.TestCase):
    def test_metrics_fragments_do_not_read_state_or_replace_cloudwatch_configuration(self):
        for target in deploy.METRICS_TARGETS:
            with self.subTest(target=target), tempfile.TemporaryDirectory() as directory:
                output = Path(directory) / 'fragment'
                with patch('sys.argv', ['render-deploy.py', target, '--output', str(output)]), \
                     patch.object(deploy.subprocess, 'run') as run, redirect_stdout(io.StringIO()):
                    deploy.main()
                run.assert_not_called()
                settings = (json.loads(output.read_text()) if target.startswith('prod')
                            else dict(line.split('=', 1) for line in output.read_text().splitlines()))
                self.assertEqual(settings, {
                    'MARKET_HTTP_PROMETHEUS_ENABLED': 'true',
                    'MARKET_HTTP_PROMETHEUS_HOST': '0.0.0.0',
                    'MARKET_HTTP_PROMETHEUS_PORT': '9108',
                })
                self.assertEqual(output.stat().st_mode & 0o777, 0o600)

    def test_task_panels_use_direct_metrics_and_do_not_claim_reservation_percentages(self):
        dashboard = json.loads((ROOT / 'config/grafana/dashboards/prod/task-resources.json').read_text())
        self.assertEqual(dashboard['uid'], 'stockspoon-task-resources')
        for panel in dashboard['panels']:
            self.assertEqual(panel['datasource']['uid'], 'prometheus')
            self.assertNotEqual(panel['fieldConfig']['defaults']['unit'], 'percent')
            for target in panel['targets']:
                self.assertIn('environment="prod"', target['expr'])
                self.assertIn('task_id!=""', target['expr'])
                self.assertIn('ecs_service=~"${service:regex}"', target['expr'])

    def test_only_sse_panels_switch_sources_in_the_mixed_ecs_dashboard(self):
        dashboard = json.loads((ROOT / 'config/grafana/dashboards/prod/ecs-sse.json').read_text())
        ids = set()
        for panel in dashboard['panels']:
            self.assertNotIn(panel['id'], ids)
            ids.add(panel['id'])
            self.assertEqual(panel['datasource']['uid'],
                             'prometheus' if panel['id'] in [1, 7, 8] else 'cloudwatch')
        self.assertEqual(ids, set(range(1, 9)))

    def test_cloudwatch_scaling_and_alarm_sources_remain_present(self):
        scaling = (ROOT.parent / 'ecs/service_scaling.tf').read_text()
        self.assertIn('metric_name = "ActiveSSEConnections"', scaling)
        alarms = json.loads((ROOT / 'config/grafana/provisioning/alerting/prod-services-rules.json').read_text())
        sse = [r for g in alarms['groups'] for r in g['rules'] if r['uid'] == 'stockspoon-prod-market-http-sse']
        self.assertEqual(sse[0]['data'][0]['datasourceUid'], 'cloudwatch')


if __name__ == '__main__':
    unittest.main()
