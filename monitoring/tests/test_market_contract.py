import base64
import gzip
import importlib.util
import io
import json
import lzma
from pathlib import Path
import re
import shlex
import tarfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('market_deploy', ROOT / 'scripts/render-deploy.py')
deploy = importlib.util.module_from_spec(spec)
spec.loader.exec_module(deploy)


class MarketContractTest(unittest.TestCase):
    def test_http_allowlist_includes_counters_and_all_histogram_series(self):
        names = ['market_http_sse_connections', 'market_http_sse_connections_started_total',
                 'market_http_sse_connections_closed_total', 'market_http_sse_events_sent_total',
                 'market_http_sse_events_sent_bytes_total', 'market_http_valkey_pool_connections',
                 'market_http_valkey_pool_acquire_timeouts_total']
        for stem in ['market_http_sse_delivery_latency_seconds', 'market_http_valkey_pool_acquire_duration_seconds']:
            names.extend(stem + suffix for suffix in ['_bucket', '_sum', '_count'])
        for path in [ROOT.parent / 'ecs/alloy/config.alloy', ROOT / 'ai-agent/market-metrics.alloy']:
            patterns = re.findall(r'regex = "([^"]+)"', path.read_text())
            pattern = next(p for p in patterns if 'market_http_sse_connections|' in p)
            for name in names:
                self.assertIsNotNone(re.fullmatch(pattern, name), name)
            self.assertIsNone(re.fullmatch(pattern, 'market_http_private_unapproved_metric'))

    def test_production_scrape_port_and_app_configuration_agree(self):
        production = (ROOT.parent / 'ecs/environments/prod/terraform.tfvars.example').read_text()
        self.assertIn('telemetry_sse_prometheus_enabled = true', production)
        task = (ROOT.parent / 'ecs/svc_market_http.tf').read_text()
        settings = deploy.market_http_metrics_environment()
        for name, value in settings.items():
            self.assertIn(f'{{ name = "{name}", value = "{value}" }}', task)
        self.assertIn('var.telemetry_sse_prometheus_enabled ? [', task)
        alloy = (ROOT.parent / 'ecs/alloy/config.alloy').read_text()
        self.assertIn('replacement = "$1:9101"', alloy)
        rules = (ROOT.parent / 'ecs/monitoring_metrics.tf').read_text()
        self.assertIn('from_port                    = 9101', rules)
        self.assertIn('referenced_security_group_id = aws_security_group.ecs_instance.id', rules)
        self.assertNotIn('cidr_ipv4', rules)

    def test_pool_dashboard_is_present_without_opt_in_and_keeps_states(self):
        dashboard = json.loads((ROOT / 'config/grafana/dashboards/prod/ecs-sse.json').read_text())
        pool = next(p for p in dashboard['panels'] if any(
            'market_http_valkey_pool_connections{' in target.get('expr', '') for target in p['targets']))
        self.assertEqual(pool['datasource']['uid'], 'prometheus')
        self.assertIn('sum by(task_id,state)', pool['targets'][0]['expr'])
        self.assertIn('in_use', json.dumps(pool))
        self.assertIn('available', json.dumps(pool))
        self.assertIn('acquiring', json.dumps(pool))
        self.assertNotIn('or vector(0)', pool['targets'][0]['expr'])

    def test_ecs_awsvpc_metrics_use_ecs_ip_and_filter_to_local_running_service(self):
        source = (ROOT.parent / 'ecs/alloy/config.alloy').read_text()
        section = source.split('discovery.relabel "market_metrics" {', 1)[1].split('prometheus.scrape "market_metrics"', 1)[0]
        self.assertIn('targets = discovery.aws.market_tasks.targets', section)
        self.assertIn('clusters         = [sys.env("ECS_CLUSTER_ARN")]', source)
        self.assertIn('value = aws_ecs_cluster.main.arn', (ROOT.parent / 'ecs/monitoring.tf').read_text())
        permissions = (ROOT.parent / 'ecs/monitoring_discovery.tf').read_text()
        self.assertIn(':cluster/default', permissions)
        self.assertIn('__meta_ecs_ip_address', section)
        self.assertNotIn('__meta_docker_network_ip', section)
        self.assertIn('__meta_ecs_task_arn', section)
        self.assertIn('regex = "RUNNING;RUNNING"', section)
        self.assertIn('regex = sys.env("MARKET_HTTP_SERVICE")', section)
        self.assertIn('__meta_ecs_ec2_instance_private_ip', section)
        self.assertIn('action = "keepequal"', section)
        task = (ROOT.parent / 'ecs/monitoring.tf').read_text()
        self.assertIn('task_role_arn            = aws_iam_role.telemetry_alloy[0].arn', task)
        self.assertIn('aws_iam_role_policy.telemetry_alloy_discovery', task)

    def test_ecs_log_task_label_is_preserved(self):
        source = (ROOT.parent / 'ecs/alloy/config.alloy').read_text().split('loki.source.docker')[0]
        self.assertIn('__meta_docker_container_label_com_amazonaws_ecs_task_arn', source)
        self.assertIn('target_label = "task_id"', source)

    def test_streamer_scrape_requires_an_explicit_private_port(self):
        for environment in ['dev', 'prod']:
            target = environment + '-ai-agent'
            destination = {'environment': environment,
                           'cluster': 'stockspoon-v2-dev' if environment == 'dev' else 'stockspoon-v1-ai',
                           'loki_push_url': 'http://10.0.11.236:3100/loki/api/v1/push',
                           'prometheus_write_url': 'http://10.0.11.236:9090/api/v1/write'}
            self.assertNotIn(b'prometheus.scrape "streamer_metrics"', deploy.deployment_files(target, destination)['ai-agent/config.alloy'])
            rendered = deploy.deployment_files(target, destination, streamer_metrics_port=9102)['ai-agent/config.alloy']
            self.assertIn(b'127.0.0.1:9102', rendered)
            self.assertNotIn(b'__STREAMER_METRICS_PORT__', rendered)
            for port in [80, 9101, 12345, 65536]:
                with self.assertRaises(ValueError):
                    deploy.deployment_files(target, destination, streamer_metrics_port=port)
        with self.assertRaises(ValueError):
            deploy.deployment_files('server', {}, streamer_metrics_port=9102)

    def test_opt_in_bundle_fits_ssm_and_round_trips_configuration(self):
        destination = {'private_ip': '10.0.11.236', 'compose_project_name': 'test', 'aws_region': 'ap-northeast-2',
                       'loki_bucket': 'loki', 'tempo_bucket': 'tempo', 'instance_id': 'i-018b437837e804b2d'}
        payload = deploy.make_payload('server-dashboards', {'plg_tempo': {'value': destination}}, sse_prometheus=True)
        command = payload['Parameters']['commands'][0]
        self.assertLess(len(command.encode()), 24000)
        line = next(line for line in command.splitlines() if line.startswith('printf'))
        encoded = shlex.split(line.split(' | ')[0])[2]
        raw = base64.b64decode(encoded)
        archive = lzma.decompress(raw) if 'lzma.decompress' in command else gzip.decompress(raw)
        with tarfile.open(fileobj=io.BytesIO(archive)) as tar:
            document = json.load(tar.extractfile('config/grafana/dashboards/prod/ecs-sse.json'))
        panels = {p['id']: p for p in document['panels']}
        self.assertIn('market_http_sse_connections{', panels[1]['targets'][0]['expr'])
        self.assertEqual(set(range(30, 41)) - panels.keys(), set())
        self.assertTrue(all('or vector(0)' not in t['expr'] for p in document['panels'] for t in p['targets'] if 'expr' in t))
        self.assertIn('le,task_id,stream', panels[33]['targets'][0]['expr'])
        self.assertIn('le,task_id,result', panels[35]['targets'][0]['expr'])


if __name__ == '__main__':
    unittest.main()
