import json
from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[1]


class EnvironmentDashboardTest(unittest.TestCase):
    def test_development_logs_scope_services_and_panels_to_the_selected_stack(self):
        dashboard = json.loads((ROOT / 'config/grafana/dashboards/dev/service-logs.json').read_text())
        variables = dashboard['templating']['list']
        self.assertEqual([v['name'] for v in variables], ['host_role', 'cluster', 'service'])
        for variable in variables[1:]:
            self.assertIn('host_role=~"$host_role"', variable['query'])
        for panel in dashboard['panels']:
            for target in panel['targets']:
                self.assertIn('host_role=~"$host_role"', target['expr'])
        from urllib.parse import parse_qs, urlsplit
        shortcuts = {link['title']: parse_qs(urlsplit(link['url']).query)
                     for link in dashboard['links'] if link['url'].startswith('/d/')}
        for title, role in [('Backend', 'app'), ('Frontend', 'app'), ('Nginx', 'app'), ('Market HTTP', 'ai')]:
            self.assertEqual(shortcuts[title]['var-host_role'], [role])
            self.assertNotEqual(shortcuts[title]['var-service'], ['$__all'])

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
        self.assertEqual(len(dashboards), 9)

    def test_dedicated_development_dashboards_cannot_include_other_services(self):
        for service in ['frontend', 'backend']:
            dashboard = json.loads((ROOT / 'config/grafana/dashboards/dev' / (service + '.json')).read_text())
            self.assertEqual(dashboard['uid'], 'stockspoon-dev-' + service)
            self.assertEqual(dashboard['templating']['list'], [])
            for panel in dashboard['panels']:
                self.assertEqual(panel['datasource']['uid'], 'loki')
                for target in panel['targets']:
                    self.assertIn('environment="dev"', target['expr'])
                    self.assertIn('host_role="app"', target['expr'])
                    self.assertIn('service_name="' + service + '"', target['expr'])
                    self.assertNotIn('$service', target['expr'])

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
