from contextlib import contextmanager, redirect_stdout
import importlib.util
import io
import json
from pathlib import Path
import shutil
import tempfile
from types import SimpleNamespace
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('configure_alerting', ROOT / 'scripts/configure-alerting.py')
alerting = importlib.util.module_from_spec(spec)
spec.loader.exec_module(alerting)
URLS = {'prod': 'https://discord.com/api/webhooks/123/prod_token',
        'dev-app': 'https://discord.com/api/webhooks/456/app_token',
        'dev-ai': 'https://discord.com/api/webhooks/789/ai_token'}


class AlertingTest(unittest.TestCase):
    @contextmanager
    def stack(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            provisioning = root / 'grafana/provisioning/alerting'
            provisioning.mkdir(parents=True)
            for source in (ROOT / 'config/grafana/provisioning/alerting').glob('*rules.json'):
                shutil.copy(source, provisioning)
            with patch.object(alerting, 'STACK', root), patch.object(alerting, 'SECRET', root / 'prod'), patch.object(alerting, 'DEV_APP_SECRET', root / 'app'), patch.object(alerting, 'DEV_AI_SECRET', root / 'ai'):
                yield root, provisioning

    def rules(self, provisioning):
        return [r for p in provisioning.glob('*rules.json')
                for g in json.loads(p.read_text())['groups'] for r in g['rules']]

    def route(self, rule):
        labels = rule['labels']
        return 'prod' if labels['environment'] == 'prod' else 'dev-' + labels['host_role']

    def test_each_rule_uses_only_its_own_receiver(self):
        with self.stack() as (_, provisioning):
            for _ in range(2):
                alerting.render(provisioning, URLS['prod'], URLS['dev-app'], URLS['dev-ai'])
                rules = self.rules(provisioning)
                self.assertEqual(len(rules), 18)
                self.assertEqual(len({r['uid'] for r in rules}), 18)
                for rule in rules:
                    self.assertFalse(rule['isPaused'])
                    self.assertEqual(rule['notification_settings']['receiver'], alerting.RECEIVERS[self.route(rule)])
            contacts = json.loads((provisioning / 'discord.local.json').read_text())
            self.assertNotIn('policies', contacts)
            self.assertEqual({c['name'] for c in contacts['contactPoints']}, set(alerting.RECEIVERS.values()))
            self.assertTrue(all(not c['receivers'][0]['disableResolveMessage'] for c in contacts['contactPoints']))
            self.assertEqual((provisioning / 'discord.local.json').stat().st_mode & 0o777, 0o600)

    def test_one_development_webhook_never_enables_the_other_server(self):
        for selected in ['dev-app', 'dev-ai', None]:
            with self.subTest(selected=selected), self.stack() as (_, provisioning):
                alerting.render(provisioning, URLS['prod'], URLS['dev-app'] if selected == 'dev-app' else None, URLS['dev-ai'] if selected == 'dev-ai' else None)
                for rule in self.rules(provisioning):
                    enabled = self.route(rule) in ['prod', selected]
                    self.assertEqual(rule['isPaused'], not enabled)
                    if not enabled:
                        self.assertNotIn('notification_settings', rule)

    def test_missing_webhooks_pause_all_rules(self):
        with self.stack() as (_, provisioning):
            alerting.render(provisioning, None)
            self.assertTrue(all(r['isPaused'] for r in self.rules(provisioning)))
            self.assertFalse((provisioning / 'discord.local.json').exists())

    def test_invalid_or_reused_urls_do_not_mutate_configuration(self):
        for urls in [('http://example.com/webhook', None, None), (URLS['prod'], URLS['prod'], None), (URLS['prod'], URLS['dev-app'], URLS['dev-app'])]:
            with self.subTest(urls=urls), self.stack() as (_, provisioning):
                before = {p.name: p.read_bytes() for p in provisioning.glob('*rules.json')}
                with self.assertRaises(ValueError):
                    alerting.render(provisioning, *urls)
                self.assertEqual(before, {p.name: p.read_bytes() for p in provisioning.glob('*rules.json')})
                self.assertFalse((provisioning / 'discord.local.json').exists())

    def test_unknown_development_host_role_is_rejected(self):
        with self.stack() as (_, provisioning):
            p = provisioning / 'dev-rules.json'
            d = json.loads(p.read_text())
            d['groups'][0]['rules'][0]['labels'].pop('host_role')
            p.write_text(json.dumps(d))
            with self.assertRaises(ValueError):
                alerting.render(provisioning, *URLS.values())
            self.assertFalse((provisioning / 'discord.local.json').exists())

    def test_aws_sync_on_fresh_server_reads_separate_parameters_without_leaks(self):
        with self.stack() as (root, provisioning):
            output = io.StringIO()
            results = [SimpleNamespace(returncode=0, stdout=v) for v in URLS.values()]
            with patch('sys.argv', ['configure-alerting.py', '--sync-aws']), patch.object(alerting.subprocess, 'run', side_effect=results) as run, redirect_stdout(output):
                alerting.main()
            for index, role in [(1, 'app'), (2, 'ai')]:
                self.assertIn(alerting.DEV_PARAMETERS[role], run.call_args_list[index].args[0])
                self.assertIn('--with-decryption', run.call_args_list[index].args[0])
            for name, value in [('prod', URLS['prod']), ('app', URLS['dev-app']), ('ai', URLS['dev-ai'])]:
                self.assertEqual((root / name).read_text().strip(), value)
                self.assertEqual((root / name).stat().st_mode & 0o777, 0o600)
                self.assertNotIn(value, output.getvalue())
            self.assertTrue(all(not r['isPaused'] for r in self.rules(provisioning)))

    def test_placeholder_pauses_only_its_server_and_clears_old_cache(self):
        with self.stack() as (root, provisioning):
            (root / 'ai').write_text(URLS['dev-ai'])
            results = [SimpleNamespace(returncode=0, stdout=v) for v in [URLS['prod'], URLS['dev-app'], 'UNCONFIGURED']]
            with patch('sys.argv', ['configure-alerting.py', '--sync-aws']), patch.object(alerting.subprocess, 'run', side_effect=results), redirect_stdout(io.StringIO()):
                alerting.main()
            self.assertEqual((root / 'ai').read_text().strip(), '')
            for rule in self.rules(provisioning):
                self.assertEqual(rule['isPaused'], self.route(rule) == 'dev-ai')

    def test_aws_failure_preserves_rules_and_cached_credentials(self):
        with self.stack() as (root, provisioning):
            (root / 'prod').write_text(URLS['prod'])
            before = {p.name: p.read_bytes() for p in provisioning.glob('*rules.json')}
            results = [SimpleNamespace(returncode=0, stdout=URLS['prod']), SimpleNamespace(returncode=255, stdout='')]
            with patch('sys.argv', ['configure-alerting.py', '--sync-aws']), patch.object(alerting.subprocess, 'run', side_effect=results):
                with self.assertRaises(SystemExit):
                    alerting.main()
            self.assertEqual(before, {p.name: p.read_bytes() for p in provisioning.glob('*rules.json')})
            self.assertEqual((root / 'prod').read_text(), URLS['prod'])
            self.assertFalse((root / 'app').exists())

    def test_configuring_app_preserves_production_and_ai(self):
        with self.stack() as (root, _):
            (root / 'prod').write_text(URLS['prod'])
            (root / 'ai').write_text(URLS['dev-ai'])
            with patch('sys.argv', ['configure-alerting.py', '--environment', 'dev', '--host-role', 'app', '--configure']), patch.object(alerting.getpass, 'getpass', return_value=URLS['dev-app']), redirect_stdout(io.StringIO()):
                alerting.main()
            self.assertEqual((root / 'prod').read_text(), URLS['prod'])
            self.assertEqual((root / 'ai').read_text(), URLS['dev-ai'])
            self.assertEqual((root / 'app').read_text().strip(), URLS['dev-app'])

    def test_legacy_production_command_keeps_the_existing_secret(self):
        with self.stack() as (root, _):
            with patch('sys.argv', ['configure-alerting.py', '--existing-channel']), patch.object(alerting.subprocess, 'run', return_value=SimpleNamespace(returncode=0, stdout=URLS['prod'])) as run, redirect_stdout(io.StringIO()):
                alerting.main()
            self.assertIn('stockspoon/v1/app/discord-webhook', run.call_args.args[0])
            self.assertEqual((root / 'prod').read_text().strip(), URLS['prod'])

    def test_development_cannot_use_production_channel_or_ambiguous_role(self):
        for args in [['--existing-channel', '--environment', 'dev'], ['--environment', 'dev', '--configure']]:
            with self.subTest(args=args), patch('sys.argv', ['configure-alerting.py', *args]), patch.object(alerting.subprocess, 'run') as run, patch('sys.stderr', io.StringIO()):
                with self.assertRaises(SystemExit):
                    alerting.main()
                run.assert_not_called()

    def test_development_queries_filter_the_host_role_before_aggregation(self):
        for group in json.loads((ROOT / 'config/grafana/provisioning/alerting/dev-rules.json').read_text())['groups']:
            for rule in group['rules']:
                expr = rule['data'][0]['model']['expr']
                self.assertIn('host_role="' + rule['labels']['host_role'] + '"', expr)
                self.assertLessEqual(len(rule['uid']), 40)
        for source, role in [('dev-agent/config.alloy', 'app'), ('ai-agent/config.alloy', 'ai')]:
            self.assertEqual((ROOT / source).read_text().count('host_role = "' + role + '"'), 2)


if __name__ == '__main__':
    unittest.main()
