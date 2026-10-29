import json
from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[1]


class BackendMetricsTest(unittest.TestCase):
    def test_backend_discovery_is_opt_in_host_local_and_unauthenticated(self):
        source = (ROOT.parent / 'ecs/alloy/config.alloy').read_text()
        block = source.split('discovery.aws "backend_tasks" {', 1)[1].split('prometheus.remote_write "server"', 1)[0]
        for required in ['BACKEND_PROMETHEUS_ENABLED', 'BACKEND_SERVICE',
                         '__meta_ecs_last_status', 'RUNNING;RUNNING',
                         '__meta_ecs_ec2_instance_private_ip', 'action = "keepequal"',
                         'metrics_path = "/actuator/prometheus"',
                         'follow_redirects = false',
                         'target_label = "task_id"', 'replacement = "backend"']:
            self.assertIn(required, block)
        # Internal scraping no longer carries a temporary JWT cookie.
        self.assertNotIn('http_headers', block)
        self.assertNotIn('Cookie', block)
        config = (ROOT.parent / 'ecs/backend_metrics.tf').read_text()
        self.assertIn('default     = false', config)
        self.assertIn('referenced_security_group_id = aws_security_group.ecs_instance.id', config)
        self.assertNotIn('cidr_ipv4', config)
        self.assertIn('var.backend_container_port', config)
        self.assertNotIn('BACKEND_METRICS_COOKIE', config)
        alloy_task = (ROOT.parent / 'ecs/monitoring.tf').read_text()
        self.assertNotIn('BACKEND_METRICS_COOKIE', alloy_task)

    def test_public_alb_blocks_unauthenticated_metrics(self):
        config = (ROOT.parent / 'ecs/backend_metrics.tf').read_text()
        rule = config.split('resource "aws_lb_listener_rule" "backend_actuator_block" {', 1)[1]
        self.assertIn('data.terraform_remote_state.app.outputs.https_listener_arn', rule)
        self.assertIn('type = "fixed-response"', rule)
        self.assertIn('status_code  = "404"', rule)
        self.assertNotIn('count', rule.split('action {', 1)[0])
        for path in ['"/actuator/prometheus"', '"/actuator/prometheus/*"', '"/actuator/metrics"', '"/actuator/metrics/*"']:
            self.assertIn(path, rule)
        self.assertIn('var.backend_actuator_block_rule_priority < var.backend_canary_rule_priority', config)
        self.assertIn('var.backend_actuator_block_rule_priority < var.market_http_rule_priority', config)
        variables = (ROOT.parent / 'ecs/variables.tf').read_text()
        routing = variables.split('variable "backend_path_patterns" {', 1)[1].split('\n}\n', 1)[0]
        self.assertIn('default     = ["/api/*"]', routing)
        self.assertIn('"actuator"', routing)

    def test_dashboard_compares_tasks_and_preserves_missing_data(self):
        dashboard = json.loads((ROOT / 'config/grafana/dashboards/prod/backend.json').read_text())
        self.assertEqual(dashboard['uid'], 'stockspoon-prod-backend')
        self.assertTrue(dashboard['templating']['list'][0]['includeAll'])
        exprs = [t['expr'] for panel in dashboard['panels'] for t in panel['targets']]
        combined = '\n'.join(exprs)
        for required in ['http_server_requests_seconds_bucket', 'tomcat_threads_busy_threads',
                         'hikaricp_connections_pending', 'container_cpu_usage_seconds_total', 'up{']:
            self.assertIn(required, combined)
        for expr in exprs:
            self.assertIn('environment="prod"', expr)
            self.assertIn('task_id=~"${task:regex}"', expr)
            self.assertNotIn('or vector(0)', expr)
        for panel in dashboard['panels']:
            if '응답시간' in panel['title']:
                self.assertIn('uri!~"/actuator.*"', panel['targets'][0]['expr'])

class DashboardDeployTest(unittest.TestCase):
    def test_payload_changes_only_backend_dashboard_without_restarts(self):
        import importlib.util
        import subprocess
        spec = importlib.util.spec_from_file_location('backend_dashboard', ROOT / 'scripts/render-backend-dashboard.py')
        deploy = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(deploy)
        payload = deploy.make_payload('i-0123456789abcdef0')
        command = payload['Parameters']['commands'][0]
        subprocess.run(['bash', '-n'], input=command, text=True, check=True)
        self.assertNotIn('docker compose', command)
        self.assertNotIn('configure-alerting', command)
        self.assertNotIn('send-command', command)
        self.assertIn('"$directory/backend.json"', command)
        with self.assertRaises(ValueError):
            deploy.make_payload('invalid')


if __name__ == '__main__':
    unittest.main()
