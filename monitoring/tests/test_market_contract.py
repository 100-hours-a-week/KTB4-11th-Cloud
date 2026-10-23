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
        payload = deploy.make_payload('server', {'plg_tempo': {'value': destination}}, sse_prometheus=True)
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
        self.assertIn('le,stream', panels[33]['targets'][0]['expr'])
        self.assertIn('le,result', panels[35]['targets'][0]['expr'])


if __name__ == '__main__':
    unittest.main()
