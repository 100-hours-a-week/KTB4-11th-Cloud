import copy
import importlib.util
import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import Mock, patch

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('ai_alert_migration', ROOT / 'scripts/migrate-ai-host-alerts.py')
migration = importlib.util.module_from_spec(spec)
spec.loader.exec_module(migration)


class AiHostMigrationTest(unittest.TestCase):
    def test_only_four_host_alarms_and_ai_scoped_rules_are_selected(self):
        doc = migration.load_source(migration.SOURCE)
        self.assertEqual(len(doc['cloudwatch_alarms']), 4)
        for alarm in doc['cloudwatch_alarms']:
            self.assertNotIn('container', alarm)
            self.assertNotIn('scheduled', alarm)
            self.assertNotIn('ec2-status', alarm)
        self.assertEqual({r['uid'] for r in doc['rules']}, migration.UIDS)
        for r in doc['rules']:
            self.assertEqual(r['notification_settings']['receiver'], migration.RECEIVER)
            self.assertFalse(r['isPaused'])
        self.assertIn('>= bool 85', doc['rules'][1]['data'][0]['model']['expr'])
        self.assertEqual(doc['rules'][1]['data'][1]['model']['conditions'][0]['evaluator']['params'], [2.5])
        self.assertEqual(doc['rules'][2]['data'][1]['model']['conditions'][0]['evaluator']['params'], [4.5])

    def test_unrelated_rule_in_group_blocks_any_mutation(self):
        source = migration.load_source(migration.SOURCE)
        api = Mock()
        api.request.side_effect = [[{'uid': 'foreign', 'folderUID': 'folder', 'ruleGroup': migration.GROUP}], [{'uid': 'folder', 'title': 'Stockspoon'}]]
        with self.assertRaisesRegex(ValueError, 'outside this migration'):
            migration.overview(api, source)
        self.assertTrue(all(c.args[0] == 'GET' for c in api.request.call_args_list))

    def test_foreign_production_host_rule_is_rejected(self):
        source = migration.load_source(migration.SOURCE)
        source['rules'][0]['data'][0]['model']['expr'] = 'node_cpu_seconds_total{environment="prod"}'
        with tempfile.TemporaryDirectory() as tmp:
            p = Path(tmp) / 'rules.json'; p.write_text(json.dumps(source))
            with self.assertRaisesRegex(ValueError, 'only production ai-v1'):
                migration.load_source(p)

    def test_changed_review_blocks_before_secret_read_or_mutation(self):
        source = migration.load_source(migration.SOURCE)
        api = Mock()
        with tempfile.TemporaryDirectory() as tmp, patch.object(migration, 'overview', return_value={}), patch.object(migration, 'secret') as secret:
            with self.assertRaisesRegex(ValueError, 'changed after review'):
                migration.apply(api, source, Path(tmp) / 'backup', 'wrong')
            api.request.assert_not_called()
            secret.assert_not_called()

    def test_rule_verification_rejects_paused_or_wrong_receiver(self):
        source = migration.load_source(migration.SOURCE)
        state = {'rules': copy.deepcopy(source['rules']), 'contacts': [{'name': migration.RECEIVER}]}
        migration.verify_rules(state, source)
        state['rules'][0]['isPaused'] = True
        with self.assertRaisesRegex(ValueError, 'paused'):
            migration.verify_rules(state, source)


if __name__ == '__main__':
    unittest.main()
