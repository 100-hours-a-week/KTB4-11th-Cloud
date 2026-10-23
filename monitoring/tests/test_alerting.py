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

class EnvironmentRoutingTest(unittest.TestCase):
    def provision(self, path):
        for source in (ROOT / 'config/grafana/provisioning/alerting').glob('*rules.json'):
            shutil.copy(source, path)

    def rules(self, path):
        return [rule for source in path.glob('*rules.json')
                for group in json.loads(source.read_text())['groups'] for rule in group['rules']]

    def test_missing_development_webhook_never_falls_back_to_production(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory)
            self.provision(path)
            alerting.render(path, 'https://discord.com/api/webhooks/123/prod_token')
            for rule in self.rules(path):
                if rule['labels']['environment'] == 'dev':
                    self.assertTrue(rule['isPaused'])
                    self.assertNotIn('notification_settings', rule)
                else:
                    self.assertFalse(rule['isPaused'])
                    self.assertEqual(rule['notification_settings']['receiver'], 'stockspoon-discord')

    def test_development_and_production_have_independent_receivers(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory)
            self.provision(path)
            for _ in range(2):
                alerting.render(path, 'https://discord.com/api/webhooks/123/prod_token', 'https://discord.com/api/webhooks/456/dev_token')
                rules = self.rules(path)
                self.assertEqual(len(rules), 12)
                self.assertEqual(len({rule['uid'] for rule in rules}), 12)
                for rule in rules:
                    self.assertFalse(rule['isPaused'])
                    receiver = 'stockspoon-discord-dev' if rule['labels']['environment'] == 'dev' else 'stockspoon-discord'
                    self.assertEqual(rule['notification_settings']['receiver'], receiver)
            contacts = json.loads((path / 'discord.local.json').read_text())['contactPoints']
            self.assertEqual({c['name'] for c in contacts}, {'stockspoon-discord', 'stockspoon-discord-dev'})

    def test_same_webhook_is_rejected_before_changing_rules(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory)
            self.provision(path)
            before = {p.name: p.read_bytes() for p in path.glob('*rules.json')}
            with self.assertRaises(ValueError):
                alerting.render(path, 'https://discord.com/api/webhooks/123/same', 'https://discord.com/api/webhooks/123/same')
            self.assertEqual(before, {p.name: p.read_bytes() for p in path.glob('*rules.json')})
            self.assertFalse((path / 'discord.local.json').exists())

    def test_existing_channel_cannot_be_used_for_development(self):
        with patch('sys.argv', ['configure-alerting.py', '--existing-channel', '--environment', 'dev']), patch.object(alerting.subprocess, 'run') as run, patch('sys.stderr', io.StringIO()):
            with self.assertRaises(SystemExit):
                alerting.main()
            run.assert_not_called()

    def test_configuring_development_preserves_the_production_secret(self):
        with tempfile.TemporaryDirectory() as directory:
            stack = Path(directory)
            provisioning = stack / 'grafana/provisioning/alerting'
            provisioning.mkdir(parents=True)
            self.provision(provisioning)
            prod, dev = stack / 'prod-secret', stack / 'dev-secret'
            prod.write_text('https://discord.com/api/webhooks/123/prod_token\n')
            with patch.object(alerting, 'STACK', stack), patch.object(alerting, 'SECRET', prod), patch.object(alerting, 'DEV_SECRET', dev), patch('sys.argv', ['configure-alerting.py', '--configure', '--environment', 'dev']), patch.object(alerting.getpass, 'getpass', return_value='https://discord.com/api/webhooks/456/dev_token'), redirect_stdout(io.StringIO()):
                alerting.main()
            self.assertEqual(prod.read_text(), 'https://discord.com/api/webhooks/123/prod_token\n')
            self.assertEqual(dev.stat().st_mode & 0o777, 0o600)

class AwsSecretSyncTest(unittest.TestCase):
    def prepare(self, stack):
        directory = stack / 'grafana/provisioning/alerting'
        directory.mkdir(parents=True)
        for source in (ROOT / 'config/grafana/provisioning/alerting').glob('*rules.json'):
            shutil.copy(source, directory)
        return directory

    def test_unconfigured_ssm_pauses_only_development_and_does_not_leak_values(self):
        with tempfile.TemporaryDirectory() as directory:
            stack = Path(directory)
            provisioning = self.prepare(stack)
            prod, dev = stack / 'prod-cache', stack / 'dev-cache'
            output = io.StringIO()
            results = [SimpleNamespace(returncode=0, stdout='https://discord.com/api/webhooks/123/prod_token'), SimpleNamespace(returncode=0, stdout='UNCONFIGURED')]
            with patch.object(alerting, 'STACK', stack), patch.object(alerting, 'SECRET', prod), patch.object(alerting, 'DEV_SECRET', dev), patch('sys.argv', ['configure-alerting.py', '--sync-aws']), patch.object(alerting.subprocess, 'run', side_effect=results) as run, redirect_stdout(output):
                alerting.main()
            self.assertIn('--with-decryption', run.call_args_list[1].args[0])
            self.assertIn(alerting.DEV_PARAMETER, run.call_args_list[1].args[0])
            for source in provisioning.glob('*rules.json'):
                for group in json.loads(source.read_text())['groups']:
                    for rule in group['rules']:
                        self.assertEqual(rule['isPaused'], rule['labels']['environment'] == 'dev')
            self.assertNotIn('prod_token', output.getvalue())
            self.assertEqual(dev.read_text().strip(), '')

    def test_fresh_server_reads_both_webhooks_from_aws_without_local_credentials(self):
        with tempfile.TemporaryDirectory() as directory:
            stack = Path(directory)
            provisioning = self.prepare(stack)
            prod, dev = stack / 'prod-cache', stack / 'dev-cache'
            results = [SimpleNamespace(returncode=0, stdout='https://discord.com/api/webhooks/123/prod_token'), SimpleNamespace(returncode=0, stdout='https://discord.com/api/webhooks/456/dev_token')]
            with patch.object(alerting, 'STACK', stack), patch.object(alerting, 'SECRET', prod), patch.object(alerting, 'DEV_SECRET', dev), patch('sys.argv', ['configure-alerting.py', '--sync-aws']), patch.object(alerting.subprocess, 'run', side_effect=results), redirect_stdout(io.StringIO()):
                alerting.main()
            for source in provisioning.glob('*rules.json'):
                for group in json.loads(source.read_text())['groups']:
                    self.assertTrue(all(not rule['isPaused'] for rule in group['rules']))
            self.assertIn('dev_token', dev.read_text())
            self.assertEqual(dev.stat().st_mode & 0o777, 0o600)
            self.assertEqual(prod.stat().st_mode & 0o777, 0o600)

    def test_aws_read_failure_preserves_provisioning_and_local_cache(self):
        with tempfile.TemporaryDirectory() as directory:
            stack = Path(directory)
            provisioning = self.prepare(stack)
            prod, dev = stack / 'prod-cache', stack / 'dev-cache'
            prod.write_text('https://discord.com/api/webhooks/123/old_prod')
            dev.write_text('https://discord.com/api/webhooks/456/old_dev')
            before = {p.name: p.read_bytes() for p in provisioning.glob('*rules.json')}
            results = [SimpleNamespace(returncode=0, stdout='https://discord.com/api/webhooks/123/new_prod'), SimpleNamespace(returncode=255, stdout='')]
            with patch.object(alerting, 'STACK', stack), patch.object(alerting, 'SECRET', prod), patch.object(alerting, 'DEV_SECRET', dev), patch('sys.argv', ['configure-alerting.py', '--sync-aws']), patch.object(alerting.subprocess, 'run', side_effect=results):
                with self.assertRaises(SystemExit):
                    alerting.main()
            self.assertEqual(before, {p.name: p.read_bytes() for p in provisioning.glob('*rules.json')})
            self.assertIn('old_prod', prod.read_text())
            self.assertIn('old_dev', dev.read_text())


if __name__ == '__main__':
    unittest.main()
