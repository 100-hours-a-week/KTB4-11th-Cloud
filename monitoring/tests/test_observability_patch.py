import importlib.util
import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import Mock

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('obs_patch', ROOT / 'scripts/deploy-observability-patch.py')
patch = importlib.util.module_from_spec(spec)
spec.loader.exec_module(patch)


class ObservabilityPatchTest(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.stack = self.root / 'stack'
        self.bundle = self.root / 'bundle'
        self.backup = self.root / 'backup'
        patch.prepare(self.bundle)
        for relative, ids in patch.PANELS.items():
            source = ROOT / 'config/grafana/dashboards' / relative
            doc = json.loads(source.read_text())
            if relative == 'prod/ecs-sse.json':
                for p in doc['panels']:
                    if p['id'] in ids:
                        p['targets'][0]['legendFormat'] = 'before'
                    if p['id'] == 2:
                        p['targets'] = [{'expr': 'live_prometheus_task_count'}]
            else:
                doc['panels'] = [p for p in doc['panels'] if p['id'] not in ids]
            doc['description'] = 'live custom description'
            dest = self.stack / 'grafana/dashboards' / relative
            dest.parent.mkdir(parents=True, exist_ok=True)
            dest.write_bytes(patch.encode(doc))
        self.protected = {}
        for relative in ['grafana/dashboards/prod/frontend.json', 'grafana/dashboards/prod/proxysql.json',
                         'grafana/provisioning/alerting/rules.json', 'grafana/provisioning/alerting/prod-services-rules.json',
                         'prometheus.yaml', 'compose.yaml', '.env']:
            dest = self.stack / relative
            dest.parent.mkdir(parents=True, exist_ok=True)
            dest.write_bytes(b'{"uid":"protected-' + dest.stem.encode() + b'","note":"live setting including pause/routing state"}' if 'dashboards' in relative else b'live setting including pause/routing state')
            self.protected[relative] = dest.read_bytes()

    def test_only_selected_panels_change_and_rollback_restores_exact_bytes(self):
        before = {r: (self.stack / 'grafana/dashboards' / r).read_bytes() for r in patch.PANELS}
        changed = patch.apply(self.stack, self.bundle, self.backup)
        self.assertEqual(set(changed), set(patch.PANELS))
        for relative, data in before.items():
            old = json.loads(data)
            new = json.loads((self.stack / 'grafana/dashboards' / relative).read_text())
            self.assertEqual(new['description'], old['description'])
            for panel in old['panels']:
                if panel['id'] not in patch.PANELS[relative]:
                    self.assertIn(panel, new['panels'])
        for relative, data in self.protected.items():
            self.assertEqual((self.stack / relative).read_bytes(), data)
        self.assertEqual(patch.plan(self.stack, self.bundle)[1], [])
        patch.rollback(self.stack, self.backup)
        for relative, data in before.items():
            self.assertEqual((self.stack / 'grafana/dashboards' / relative).read_bytes(), data)

    def test_missing_backend_is_created_and_rollback_removes_only_new_file(self):
        path = self.stack / 'grafana/dashboards/prod/backend.json'
        path.unlink()
        api = Mock()
        api.request.return_value = None
        api.rule.return_value = None
        review = patch.inspection(self.stack, self.bundle, api)
        self.assertIn({'path': 'prod/backend.json', 'action': 'create', 'before': None,
                       'after': next(c for c in review['dashboard_changes'] if c['path'] == 'prod/backend.json')['after']}, review['dashboard_changes'])
        patch.apply(self.stack, self.bundle, self.backup)
        self.assertTrue(path.is_file())
        patch.rollback(self.stack, self.backup)
        self.assertFalse(path.exists())
        for relative, data in self.protected.items():
            self.assertEqual((self.stack / relative).read_bytes(), data)

    def test_missing_backend_refuses_uid_collision_in_grafana(self):
        (self.stack / 'grafana/dashboards/prod/backend.json').unlink()
        api = Mock()
        api.request.return_value = {'dashboard': {'uid': 'stockspoon-prod-backend'}}
        with self.assertRaisesRegex(ValueError, 'exists in Grafana'):
            patch.inspection(self.stack, self.bundle, api)
        with self.assertRaisesRegex(ValueError, 'verification is required'):
            patch.inspection(self.stack, self.bundle)

    def test_requested_titles_are_applied_without_changing_uid_or_other_fields(self):
        for relative in patch.TITLES:
            path = self.stack / 'grafana/dashboards' / relative
            doc = json.loads(path.read_text())
            doc['title'] = 'Previous deployed title'
            path.write_bytes(patch.encode(doc))
        patch.apply(self.stack, self.bundle, self.backup)
        for relative, expected in patch.TITLES.items():
            doc = json.loads((self.stack / 'grafana/dashboards' / relative).read_text())
            self.assertEqual(doc['title'], expected)
            source = json.loads((ROOT / 'config/grafana/dashboards' / relative).read_text())
            self.assertEqual(doc['uid'], source['uid'])
            self.assertEqual(doc['description'], 'live custom description')

    def test_collision_and_uid_mismatch_fail_before_writes(self):
        path = self.stack / 'grafana/dashboards/prod/backend.json'
        doc = json.loads(path.read_text())
        doc['panels'].append({'id': 12, 'title': 'another live panel'})
        path.write_bytes(patch.encode(doc))
        with self.assertRaisesRegex(ValueError, 'occupied'):
            patch.apply(self.stack, self.bundle, self.backup)
        self.assertFalse(self.backup.exists())
        doc['uid'] = 'foreign-dashboard'
        path.write_bytes(patch.encode(doc))
        with self.assertRaisesRegex(ValueError, 'UID mismatch'):
            patch.plan(self.stack, self.bundle)

    def test_api_failure_restores_dashboard_files(self):
        before = {r: (self.stack / 'grafana/dashboards' / r).read_bytes() for r in patch.PANELS}
        api = Mock()
        api.create.side_effect = RuntimeError('API unavailable')
        with self.assertRaises(RuntimeError):
            patch.apply(self.stack, self.bundle, self.backup, api)
        for relative, data in before.items():
            self.assertEqual((self.stack / 'grafana/dashboards' / relative).read_bytes(), data)
        with self.assertRaisesRegex(ValueError, 'result uncertain'):
            patch.rollback(self.stack, self.backup, api)

    def test_rollback_refuses_later_operator_changes(self):
        patch.apply(self.stack, self.bundle, self.backup)
        path = self.stack / 'grafana/dashboards/prod/backend.json'
        path.write_bytes(path.read_bytes() + b' ')
        with self.assertRaisesRegex(ValueError, 'changed after deployment'):
            patch.rollback(self.stack, self.backup)

    def test_rollback_deletes_only_the_rule_created_by_this_deployment(self):
        created = {'uid': patch.AI_UID, 'isPaused': True}
        api = Mock()
        api.create.return_value = created
        api.rule.return_value = created
        patch.apply(self.stack, self.bundle, self.backup, api)
        patch.rollback(self.stack, self.backup, api)
        api.request.assert_called_once_with('DELETE', '/api/v1/provisioning/alert-rules/' + patch.AI_UID)

    def test_changed_ai_rule_blocks_rollback_before_files_are_restored(self):
        api = Mock()
        api.create.return_value = {'uid': patch.AI_UID, 'isPaused': True}
        patch.apply(self.stack, self.bundle, self.backup, api)
        before = (self.stack / 'grafana/dashboards/prod/backend.json').read_bytes()
        api.rule.return_value = {'uid': patch.AI_UID, 'isPaused': False}
        with self.assertRaisesRegex(ValueError, 'AI alert changed'):
            patch.rollback(self.stack, self.backup, api)
        self.assertEqual((self.stack / 'grafana/dashboards/prod/backend.json').read_bytes(), before)
        api.request.assert_not_called()

    def test_preview_changes_when_live_dashboard_changes(self):
        before = patch.inspection(self.stack, self.bundle)['fingerprint']
        path = self.stack / 'grafana/dashboards/prod/backend.json'
        path.write_bytes(path.read_bytes() + b' ')
        self.assertNotEqual(before, patch.inspection(self.stack, self.bundle)['fingerprint'])

    def test_api_refuses_rule_owned_by_file_provisioning(self):
        source = json.loads((self.bundle / 'patch.json').read_text())['ai_rule']
        with self.assertRaisesRegex(ValueError, 'file-provisioned'):
            patch.assert_rule_matches(dict(source, provenance='file'), source)

    def test_each_target_selects_only_its_allowlisted_dashboard(self):
        for target, expected in patch.TARGETS.items():
            bundle = self.root / target
            patch.prepare(bundle, target)
            doc, changes = patch.plan(self.stack, bundle)
            self.assertEqual(set(doc['dashboards']), set(expected))
            self.assertEqual({c[1] for c in changes}, set(expected))

    def test_existing_ai_alert_is_never_modified(self):
        api = object.__new__(patch.Grafana)
        source = json.loads((self.bundle / 'patch.json').read_text())['ai_rule']
        existing = dict(source, isPaused=False, notification_settings={'receiver': 'custom'})
        api.rule = Mock(return_value=existing)
        api.request = Mock()
        self.assertIsNone(api.create(source))
        api.request.assert_not_called()

    def test_new_alert_is_created_paused_without_reload(self):
        api = object.__new__(patch.Grafana)
        api.rule = Mock(side_effect=[None, {'uid': patch.AI_UID, 'isPaused': True}])
        api.request = Mock(side_effect=[[{'uid': 'folder', 'title': 'Stockspoon'}], [], {}])
        source = json.loads((self.bundle / 'patch.json').read_text())['ai_rule']
        api.create(source)
        call = api.request.call_args_list[-1]
        self.assertEqual(call.args[0], 'POST')
        self.assertEqual(call.args[1], '/api/v1/provisioning/alert-rules')
        self.assertTrue(call.args[2]['isPaused'])
        self.assertEqual(call.args[2]['folderUID'], 'folder')


if __name__ == '__main__':
    unittest.main()
