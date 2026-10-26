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
                expected = {
                    'MARKET_HTTP_PROMETHEUS_BIND_HOST': '0.0.0.0',
                    'MARKET_HTTP_PROMETHEUS_PORT': '9101',
                }
                if target == 'dev-ai-metrics':
                    expected.update({'MARKET_STREAMER_PROMETHEUS_BIND_HOST': '0.0.0.0',
                                     'MARKET_STREAMER_PROMETHEUS_PORT': '9102'})
                self.assertEqual(settings, expected)
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
        destination = {
            'private_ip': '10.0.11.236', 'compose_project_name': 'test',
            'aws_region': 'ap-northeast-2', 'loki_bucket': 'test-loki', 'tempo_bucket': 'test-tempo',
        }
        default = deploy.deployment_files('server', destination)
        name = 'config/grafana/dashboards/prod/ecs-sse.json'
        self.assertEqual(default[name], deploy.deployment_files('server', destination, sse_prometheus=True)[name])
        files = deploy.deployment_files('server', destination, sse_prometheus=True)
        dashboard = json.loads(files[name])
        ids = set()
        for panel in dashboard['panels']:
            self.assertNotIn(panel['id'], ids)
            ids.add(panel['id'])
            self.assertEqual(panel['datasource']['uid'],
                             'prometheus' if (panel['id'] in [1, 7, 8, 20, 21] or panel['id'] >= 30) else
                             'loki' if panel['id'] >= 22 else 'cloudwatch')
        self.assertEqual(ids, set(range(1, 9)) | set(range(20, 26)) | set(range(30, 41)))
        baseline = {p['id']: p for p in json.loads(default[name])['panels']}
        for panel in dashboard['panels']:
            if 20 <= panel['id'] <= 25:
                self.assertEqual(panel['targets'], baseline[panel['id']]['targets'])
                for target in panel['targets']:
                    self.assertIn('environment="prod"', target['expr'])
                    self.assertIn('market-http', target['expr'])
                    self.assertNotIn('$service', target['expr'])
        for index, left in enumerate(dashboard['panels']):
            a = left['gridPos']
            for right in dashboard['panels'][index + 1:]:
                b = right['gridPos']
                self.assertFalse(a['x'] < b['x'] + b['w'] and b['x'] < a['x'] + a['w']
                                 and a['y'] < b['y'] + b['h'] and b['y'] < a['y'] + a['h'])

    def test_market_task_filter_matches_resource_logs_and_optional_sse(self):
        dashboard = json.loads((ROOT / 'config/grafana/dashboards/prod/ecs-sse.json').read_text())
        variable = next(v for v in dashboard['templating']['list'] if v['name'] == 'task')
        self.assertEqual(variable['allValue'], '.*')
        self.assertIn('ecs_service="stockspoon-v2-prod-market-http"', variable['query'])
        for panel in dashboard['panels']:
            if 20 <= panel['id'] <= 36:
                for target in panel['targets']:
                    self.assertIn('task_id=~"${task:regex}"', target['expr'])
                    self.assertNotIn('or vector(0)', target['expr'])
        override = json.loads((ROOT / 'overrides/sse-prometheus.json').read_text())
        for panel in override['panels']:
            if panel['id'] >= 37:
                self.assertNotIn('task_id', panel['targets'][0]['expr'])
                continue
            self.assertIn('task_id=~"${task:regex}"', panel['targets'][0]['expr'])
        source = (ROOT.parent / 'ecs/alloy/config.alloy').read_text().split('loki.source.docker')[0]
        self.assertIn('__meta_docker_container_label_com_amazonaws_ecs_task_arn', source)
        self.assertIn('target_label = "task_id"', source)

    def test_ai_scraping_stays_off_until_explicitly_requested(self):
        destination = {
            'environment': 'dev', 'cluster': 'stockspoon-v2-dev',
            'loki_push_url': 'http://10.0.11.236:3100/loki/api/v1/push',
            'prometheus_write_url': 'http://10.0.11.236:9090/api/v1/write',
        }
        name = 'ai-agent/config.alloy'
        default = deploy.deployment_files('dev-ai-agent', destination)[name]
        enabled = deploy.deployment_files('dev-ai-agent', destination, sse_prometheus=True)[name]
        self.assertNotIn(b'prometheus.scrape "market_metrics"', default)
        self.assertIn(b'prometheus.scrape "market_metrics"', enabled)
        with self.assertRaises(ValueError):
            deploy.deployment_files('prod-ai-agent', destination, sse_prometheus=True)

    def test_cloudwatch_scaling_and_alarm_sources_remain_present(self):
        scaling = (ROOT.parent / 'ecs/service_scaling.tf').read_text()
        self.assertIn('metric_name = "ActiveSSEConnections"', scaling)
        alarms = json.loads((ROOT / 'config/grafana/provisioning/alerting/prod-services-rules.json').read_text())
        sse = [r for g in alarms['groups'] for r in g['rules'] if r['uid'] == 'stockspoon-prod-market-http-sse']
        self.assertEqual(sse[0]['data'][0]['datasourceUid'], 'cloudwatch')


if __name__ == '__main__':
    unittest.main()
