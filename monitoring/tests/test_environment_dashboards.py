import json
from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[1]


class EnvironmentDashboardTest(unittest.TestCase):
    def test_log_and_host_queries_are_fixed_to_the_folder_environment(self):
        for environment in ['dev', 'prod']:
            for name in ['overview', 'service-logs']:
                with self.subTest(environment=environment, dashboard=name):
                    source = ROOT / 'config/grafana/dashboards' / environment / (name + '.json')
                    dashboard = json.loads(source.read_text())
                    self.assertNotIn('$environment', source.read_text())
                    for panel in dashboard['panels']:
                        for target in panel.get('targets', []):
                            self.assertIn('environment="' + environment + '"', target['expr'])
                    for variable in dashboard['templating']['list']:
                        if variable['type'] == 'query':
                            self.assertIn('environment="' + environment + '"', variable['query'])

    def test_dashboard_uids_remain_unique_and_production_bookmarks_are_preserved(self):
        dashboards = [json.loads(p.read_text()) for p in (ROOT / 'config/grafana/dashboards').rglob('*.json')]
        uids = [d['uid'] for d in dashboards]
        self.assertEqual(len(set(uids)), len(uids))
        self.assertTrue({'stockspoon-overview', 'stockspoon-service-logs', 'stockspoon-ecs-sse', 'stockspoon-task-resources', 'stockspoon-alb'} <= set(uids))
        self.assertEqual(len(dashboards), 7)

    def test_all_alert_queries_match_their_routing_environment(self):
        uids = []
        for path in (ROOT / 'config/grafana/provisioning/alerting').glob('*rules.json'):
            for group in json.loads(path.read_text())['groups']:
                for rule in group['rules']:
                    uids.append(rule['uid'])
                    environment = rule['labels']['environment']
                    model = rule['data'][0]['model']
                    if rule['data'][0]['datasourceUid'] == 'cloudwatch':
                        self.assertEqual(environment, 'prod')
                        dimensions = model['dimensions']
                        self.assertTrue(dimensions.get('ClusterName') == 'stockspoon-v2-prod-cluster' or dimensions.get('LoadBalancer') == 'app/stockspoon-v1-alb/ebcc17bb6129bafc')
                        self.assertFalse(any('$' in value for value in dimensions.values()))
                    else:
                        self.assertIn('environment="' + environment + '"', model['expr'])
        self.assertEqual(len(set(uids)), len(uids))


if __name__ == '__main__':
    unittest.main()
