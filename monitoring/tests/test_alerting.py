import importlib.util
import json
from pathlib import Path
import shutil
import tempfile
import unittest
from contextlib import redirect_stdout
import io
from types import SimpleNamespace
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('configure_alerting', ROOT / 'scripts/configure-alerting.py')
alerting = importlib.util.module_from_spec(spec)
spec.loader.exec_module(alerting)


class AlertingTest(unittest.TestCase):
    def test_existing_channel_reads_secret_without_printing_webhook(self):
        with tempfile.TemporaryDirectory() as directory:
            stack = Path(directory)
            provisioning = stack / 'grafana/provisioning/alerting'
            provisioning.mkdir(parents=True)
            shutil.copy(ROOT / 'config/grafana/provisioning/alerting/rules.json', provisioning)
            webhook = 'https://discord.com/api/webhooks/123/fake_token'
            output = io.StringIO()
            with patch.object(alerting, 'STACK', stack), patch.object(alerting, 'SECRET', stack / 'secret'), patch('sys.argv', ['configure-alerting.py', '--existing-channel']), patch.object(alerting.subprocess, 'run', return_value=SimpleNamespace(returncode=0, stdout=webhook)) as run, redirect_stdout(output):
                alerting.main()
            self.assertIn('stockspoon/v1/app/discord-webhook', run.call_args.args[0])
            self.assertNotIn(webhook, output.getvalue())
            self.assertEqual((stack / 'secret').read_text().strip(), webhook)
            self.assertTrue((provisioning / 'discord.local.json').exists())

    def test_webhook_activation_and_redeployment_preserve_routing(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory)
            shutil.copy(ROOT / 'config/grafana/provisioning/alerting/rules.json', path)
            alerting.render(path, None)
            self.assertTrue(all(rule['isPaused'] for rule in json.loads((path / 'rules.json').read_text())['groups'][0]['rules']))
            self.assertFalse((path / 'discord.local.json').exists())
            for _ in range(2):
                alerting.render(path, 'https://discord.com/api/webhooks/123/fake_token')
                rules = json.loads((path / 'rules.json').read_text())['groups'][0]['rules']
                self.assertTrue(all(not rule['isPaused'] for rule in rules))
                self.assertTrue(all(rule['notification_settings']['receiver'] == 'stockspoon-discord' for rule in rules))
            contact = json.loads((path / 'discord.local.json').read_text())
            self.assertNotIn('policies', contact)
            self.assertFalse(contact['contactPoints'][0]['receivers'][0]['disableResolveMessage'])
            self.assertEqual((path / 'discord.local.json').stat().st_mode & 0o777, 0o600)

    def test_invalid_webhook_does_not_mutate_configuration(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory)
            shutil.copy(ROOT / 'config/grafana/provisioning/alerting/rules.json', path)
            before = (path / 'rules.json').read_bytes()
            with self.assertRaises(ValueError):
                alerting.render(path, 'http://example.com/webhook')
            self.assertEqual(before, (path / 'rules.json').read_bytes())
            self.assertFalse((path / 'discord.local.json').exists())

    def test_missing_metrics_is_detected_without_a_fixed_host_count(self):
        document = json.loads((ROOT / 'config/grafana/provisioning/alerting/rules.json').read_text())
        rules = document['groups'][0]['rules']
        missing = next(rule for rule in rules if rule['uid'] == 'stockspoon-prod-metrics-missing')
        self.assertIn('absent_over_time', missing['data'][0]['model']['expr'])
        self.assertEqual(len({rule['uid'] for rule in rules}), len(rules))
        self.assertTrue(all(rule['isPaused'] for rule in rules))
        self.assertTrue(all('environment="prod"' in rule['data'][0]['model']['expr'] for rule in rules))


if __name__ == '__main__':
    unittest.main()
