"""Validate the actual Compose environment, including enabled order-consumer defaults."""
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
COMPOSE = ROOT / 'test-infra/dev-app/docker-compose.yaml'
EXAMPLE = ROOT / 'test-infra/dev-app/.env.example'
KEYS = ('AWS_REGION', 'AI_REQUEST_QUEUE_ENABLED', 'AI_REQUEST_QUEUE_URL',
        'ORDER_QUEUE_ENABLED', 'ORDER_QUEUE_CONSUMER_ENABLED', 'ORDER_QUEUE_URL',
        'REPORT_QUEUE_ENABLED', 'REPORT_QUEUE_URL')


class DevSqsEnvironmentTest(unittest.TestCase):
    def render(self, overrides=None, remove_sqs=False):
        content = EXAMPLE.read_text()
        if remove_sqs:
            content = '\n'.join(line for line in content.splitlines()
                                if not any(line.startswith(k + '=') for k in KEYS)) + '\n'
        if overrides:
            content += '\n' + '\n'.join(k + '=' + v for k, v in overrides.items()) + '\n'
        env = dict(os.environ)
        for key in KEYS:
            env.pop(key, None)
        with tempfile.NamedTemporaryFile(mode='w', suffix='.env') as f:
            f.write(content)
            f.flush()
            result = subprocess.run(
                ['docker', 'compose', '--env-file', f.name, '-f', str(COMPOSE),
                 'config', '--format', 'json'], env=env, check=True,
                text=True, capture_output=True)
        return json.loads(result.stdout)['services']['backend']['environment']

    def test_missing_sqs_environment_defaults_order_consumer_to_true(self):
        env = self.render(remove_sqs=True)
        self.assertEqual(env['AI_REQUEST_QUEUE_ENABLED'], 'true')
        self.assertTrue(env['AI_REQUEST_QUEUE_URL'].endswith('/stockspoon-v2-dev-ai-request'))
        self.assertEqual(env['ORDER_QUEUE_CONSUMER_ENABLED'], 'true')
        self.assertEqual(env['AWS_REGION'], 'ap-northeast-2')
        self.assertEqual(env['REPORT_QUEUE_ENABLED'], 'false')

    def test_example_defaults_order_consumer_to_true(self):
        env = self.render()
        self.assertEqual(env['ORDER_QUEUE_ENABLED'], 'true')
        self.assertEqual(env['ORDER_QUEUE_CONSUMER_ENABLED'], 'true')
        self.assertTrue(env['ORDER_QUEUE_URL'].endswith('/stockspoon-v2-dev-order.fifo'))

    def test_example_passes_enabled_standard_report_queue(self):
        env = self.render()
        self.assertEqual(env['REPORT_QUEUE_ENABLED'], 'true')
        self.assertEqual(env['REPORT_QUEUE_URL'],
                         'https://sqs.ap-northeast-2.amazonaws.com/250832562715/stockspoon-v2-dev-report-request')
        self.assertFalse(env['REPORT_QUEUE_URL'].endswith('.fifo'))

    def test_explicit_report_settings_are_forwarded(self):
        env = self.render({'REPORT_QUEUE_ENABLED': 'false',
                           'REPORT_QUEUE_URL': 'https://example.com/report-queue'})
        self.assertEqual(env['REPORT_QUEUE_ENABLED'], 'false')
        self.assertEqual(env['REPORT_QUEUE_URL'], 'https://example.com/report-queue')

    def test_empty_order_consumer_setting_defaults_to_true(self):
        env = self.render({'ORDER_QUEUE_CONSUMER_ENABLED': ''})
        self.assertEqual(env['ORDER_QUEUE_CONSUMER_ENABLED'], 'true')

    def test_explicit_false_can_pause_order_consumption(self):
        env = self.render({'ORDER_QUEUE_CONSUMER_ENABLED': 'false'})
        self.assertEqual(env['ORDER_QUEUE_CONSUMER_ENABLED'], 'false')

    def test_explicit_operator_settings_are_forwarded(self):
        env = self.render({'AI_REQUEST_QUEUE_ENABLED': 'false',
                           'AI_REQUEST_QUEUE_URL': 'https://example.com/custom-queue',
                           'ORDER_QUEUE_CONSUMER_ENABLED': 'true'})
        self.assertEqual(env['AI_REQUEST_QUEUE_ENABLED'], 'false')
        self.assertEqual(env['AI_REQUEST_QUEUE_URL'], 'https://example.com/custom-queue')
        self.assertEqual(env['ORDER_QUEUE_CONSUMER_ENABLED'], 'true')


if __name__ == '__main__':
    unittest.main()
