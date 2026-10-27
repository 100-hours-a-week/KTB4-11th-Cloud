#!/usr/bin/env python3
"""Prepare locally, then check/apply a narrow Grafana patch on the monitoring host."""
import argparse
import base64
import time
import copy
import hashlib
import json
import os
from pathlib import Path
import shutil
import tempfile
import urllib.error
import urllib.request

ROOT = Path(__file__).resolve().parents[1]
PANELS = {
    'prod/ecs-sse.json': [30, 31, 32, 33, 34, 35, 36],
    'prod/backend.json': [12, 13],
    'dev/backend.json': [6, 7],
    'prod/overview.json': [10],
}
TITLES = {'prod/backend.json': 'ECS BE 모니터링', 'prod/ecs-sse.json': 'ECS 시세 서버 모니터링'}
AI_UID = 'stockspoon-prod-ai-metrics-missing'
AI_GROUP = 'stockspoon-prod-ai-host'


TARGETS = {'market': ['prod/ecs-sse.json'], 'prod-be': ['prod/backend.json'],
           'dev-be': ['dev/backend.json'], 'ai': ['prod/overview.json']}


def selected_paths(target):
    if target == 'all':
        return list(PANELS)
    if target not in TARGETS:
        raise ValueError('Unsupported deployment target')
    return TARGETS[target]


def contains(actual, desired):
    if isinstance(desired, dict):
        return isinstance(actual, dict) and all(k in actual and contains(actual[k], v) for k, v in desired.items())
    if isinstance(desired, list):
        return isinstance(actual, list) and len(actual) == len(desired) and all(contains(a, b) for a, b in zip(actual, desired))
    return actual == desired


def assert_rule_matches(existing, source):
    if existing.get('provenance') == 'file':
        raise ValueError('AI rule is still file-provisioned; migrate its ownership before API deployment')
    # Pause and notification overrides are operational state, never overwritten here.
    for key in ('uid', 'title', 'ruleGroup', 'condition', 'data', 'noDataState',
                'execErrState', 'for', 'labels', 'annotations'):
        if not contains(existing.get(key), source.get(key)):
            raise ValueError('AI rule differs from Git; review migration before updating: ' + key)


def inspection(stack, bundle, api=None):
    patch, changes = plan(stack, bundle)
    # Hash all selected dashboards, including no-ops, to detect changes after review.
    baseline = {r: digest((stack / 'grafana/dashboards' / r).read_bytes()) if (stack / 'grafana/dashboards' / r).exists() else None
                for r in selected_paths(patch.get('target', 'all'))}
    for path, relative, before, after, mode in changes:
        if not before:
            if api is None:
                raise ValueError('Grafana verification is required before creating a dashboard')
            if api.request('GET', '/api/dashboards/uid/' + patch['dashboards'][relative]['uid']) is not None:
                raise ValueError('Backend dashboard UID exists in Grafana; refusing to overwrite it')
    rule = api.rule() if api else None
    if rule:
        assert_rule_matches(rule, patch['ai_rule'])
    value = {'files': baseline, 'bundle_sha256': digest((bundle / 'patch.json').read_bytes()),
             'ai_rule_sha256': digest(encode(rule)) if api else None}
    return {'fingerprint': digest(encode(value)), 'target': patch.get('target', 'all'),
            'dashboard_changes': [{'path': c[1], 'action': 'update' if c[2] else 'create', 'before': digest(c[2]) if c[2] else None, 'after': digest(c[3])} for c in changes],
            'ai_alert': ('preserve-existing' if rule else 'create-paused') if api else 'unchanged',
            'services_restarted': []}


def verify(stack, bundle, api=None):
    patch, changes = plan(stack, bundle)
    if changes:
        raise ValueError('Deployed dashboard files differ from the bundle')
    if api:
        for attempt in range(45):
            pending = False
            for relative, update in patch['dashboards'].items():
                dashboard = api.request('GET', '/api/dashboards/uid/' + update['uid'])
                if not dashboard:
                    pending = True
                    continue
                panels = dashboard['dashboard']['panels']
                if any(not any(contains(live, p) for live in panels) for p in update['panels']):
                    pending = True
            if not pending:
                if patch.get('target', 'all') in ('ai', 'all'):
                    rule = api.rule()
                    if not rule:
                        raise ValueError('AI alert was not provisioned')
                    assert_rule_matches(rule, patch['ai_rule'])
                return
            time.sleep(2)
        raise ValueError('Grafana did not load selected panels within 90 seconds')


def digest(data):
    return hashlib.sha256(data).hexdigest()


def atomic_write(path, data, mode):
    fd, temporary = tempfile.mkstemp(prefix='.' + path.name, dir=path.parent)
    try:
        with os.fdopen(fd, 'wb') as output:
            output.write(data)
            os.fchmod(output.fileno(), mode)
        os.replace(temporary, path)
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)


def encode(value):
    return (json.dumps(value, ensure_ascii=False, indent=2) + '\n').encode()


def prepare(directory, target="all"):
    selected = selected_paths(target)
    directory.mkdir(mode=0o700, parents=True, exist_ok=False)
    dashboards = {}
    for relative, ids in PANELS.items():
        if relative not in selected:
            continue
        doc = json.loads((ROOT / 'config/grafana/dashboards' / relative).read_text())
        dashboards[relative] = {'uid': doc['uid'], 'panels': [p for p in doc['panels'] if p['id'] in ids]}
        if relative in TITLES:
            if doc['title'] != TITLES[relative]:
                raise ValueError('Dashboard source title differs from the allowed title')
            dashboards[relative]['title'] = doc['title']
        if relative == 'prod/backend.json':
            dashboards[relative]['new_dashboard'] = doc
    rule = json.loads((ROOT / 'alerts/ai-host.json').read_text())
    (directory / 'patch.json').write_bytes(encode({'dashboards': dashboards, 'ai_rule': rule, 'target': target}))
    shutil.copyfile(__file__, directory / 'deploy-observability-patch.py')


def plan(stack, bundle):
    patch = json.loads((bundle / 'patch.json').read_text())
    if set(patch['dashboards']) != set(selected_paths(patch.get('target', 'all'))):
        raise ValueError('Unexpected dashboard paths')
    changes = []
    for relative, update in patch['dashboards'].items():
        if sorted(p['id'] for p in update['panels']) != PANELS[relative]:
            raise ValueError('Unexpected panel IDs: ' + relative)
        path = stack / 'grafana/dashboards' / relative
        if not path.exists() and not path.is_symlink() and relative == 'prod/backend.json':
            doc = update.get('new_dashboard')
            if not doc or doc['uid'] != 'stockspoon-prod-backend' or doc['uid'] != update['uid']:
                raise ValueError('Unexpected new backend dashboard identity')
            # A matching UID in another provisioned file must never be duplicated.
            for other in (stack / 'grafana/dashboards').rglob('*.json'):
                if json.loads(other.read_text()).get('uid') == doc['uid']:
                    raise ValueError('Backend UID already exists in another live file')
            if not path.parent.is_dir():
                raise ValueError('Expected existing production dashboard directory')
            changes.append((path, relative, b'', encode(doc), 0o644))
            continue
        if path.is_symlink() or not path.is_file():
            raise ValueError('Expected an existing regular dashboard: ' + relative)
        before = path.read_bytes()
        doc = json.loads(before)
        if doc['uid'] != update['uid']:
            raise ValueError('Dashboard UID mismatch: ' + relative)
        if 'title' in update:
            if update['title'] != TITLES.get(relative):
                raise ValueError('Unexpected dashboard rename')
            doc['title'] = update['title']
        for panel in update['panels']:
            matches = [i for i, p in enumerate(doc['panels']) if p['id'] == panel['id']]
            if len(matches) > 1:
                raise ValueError('Duplicate panel ID: ' + relative)
            if matches:
                index = matches[0]
                if doc['panels'][index]['title'] != panel['title']:
                    raise ValueError('Panel ID occupied by another panel: ' + relative)
                doc['panels'][index] = copy.deepcopy(panel)
            else:
                # Refuse overlap with panels independently added on the live server.
                pos = panel['gridPos']
                for existing in doc['panels']:
                    q = existing.get('gridPos', {})
                    if all(k in q for k in ('x', 'y', 'w', 'h')) and (pos['x'] < q['x'] + q['w'] and q['x'] < pos['x'] + pos['w'] and pos['y'] < q['y'] + q['h'] and q['y'] < pos['y'] + pos['h']):
                        raise ValueError('New panel overlaps a live panel: ' + relative)
                doc['panels'].append(copy.deepcopy(panel))
        if doc == json.loads(before):
            continue
        doc['version'] = doc.get('version', 1) + 1
        changes.append((path, relative, before, encode(doc), path.stat().st_mode & 0o777))
    return patch, changes


class Grafana:
    def __init__(self, url):
        if url.rstrip('/') != 'http://127.0.0.1:3000':
            raise ValueError('Only the local Grafana endpoint is allowed')
        self.url = url.rstrip('/')
        token = os.environ.get('GRAFANA_TOKEN', '')
        if token:
            self.authorization = 'Bearer ' + token
        else:
            password = Path('/srv/stockspoon-telemetry/secrets/grafana_admin_password').read_text().strip()
            self.authorization = 'Basic ' + base64.b64encode(('admin:' + password).encode()).decode()

    def request(self, method, path, value=None):
        request = urllib.request.Request(self.url + path, method=method,
            data=encode(value) if value is not None else None,
            headers={'Authorization': self.authorization, 'Content-Type': 'application/json'})
        try:
            with urllib.request.urlopen(request, timeout=15) as response:
                body = response.read()
                return json.loads(body) if body else None
        except urllib.error.HTTPError as error:
            if method == 'GET' and error.code == 404:
                return None
            raise RuntimeError('Grafana request failed: HTTP ' + str(error.code)) from None

    def rule(self):
        return self.request('GET', '/api/v1/provisioning/alert-rules/' + AI_UID)

    def create(self, source):
        existing = self.rule()
        if existing is not None:
            assert_rule_matches(existing, source)
            return None  # Pause/routing state remains live; do not overwrite existing rules.
        folders = self.request('GET', '/api/folders?limit=1000')
        matches = [f['uid'] for f in folders if f['title'] == 'Stockspoon']
        if len(matches) != 1:
            raise ValueError('Expected one existing Stockspoon alert folder')
        rules = self.request('GET', '/api/v1/provisioning/alert-rules')
        if any(r.get('folderUID') == matches[0] and r.get('ruleGroup') == AI_GROUP for r in rules):
            raise ValueError('AI alert group already belongs to another live rule')
        rule = copy.deepcopy(source)
        if rule.get('uid') != AI_UID or rule.get('ruleGroup') != AI_GROUP or rule.get('isPaused') is not True:
            raise ValueError('Unexpected AI alert identity or pause state')
        rule['folderUID'] = matches[0]
        self.request('POST', '/api/v1/provisioning/alert-rules', rule)
        created = self.rule()
        if created is None or created.get('isPaused') is not True:
            raise RuntimeError('New AI rule could not be verified as paused; inspect Grafana before proceeding')
        return created


def apply(stack, bundle, backup, api=None):
    patch, changes = plan(stack, bundle)
    backup.mkdir(mode=0o700, parents=True, exist_ok=False)
    manifest = {'target': patch.get('target', 'all'), 'stack': str(stack.resolve()), 'files': [], 'created_rule': None, 'alert_result_uncertain': False}
    for path, relative, before, after, mode in changes:
        dest = backup / relative
        dest.parent.mkdir(parents=True, exist_ok=True)
        dest.write_bytes(before)
        dest.chmod(0o600)
        manifest['files'].append({'path': relative, 'before': digest(before), 'after': digest(after), 'mode': mode, 'created': not bool(before)})
    manifest_path = backup / 'manifest.json'
    manifest_path.write_bytes(encode(manifest))
    manifest_path.chmod(0o600)
    written = []
    try:
        for path, relative, before, after, mode in changes:
            if (path.read_bytes() if path.exists() else b'') != before:
                raise ValueError('Concurrent dashboard change: ' + relative)
            written.append((path, before, after, mode))
            atomic_write(path, after, mode)
        if api:
            # A timed-out POST can still have succeeded; keep a journal before sending it.
            manifest['alert_result_uncertain'] = True
            manifest_path.write_bytes(encode(manifest))
            manifest['created_rule'] = api.create(patch['ai_rule'])
            manifest['alert_result_uncertain'] = False
            manifest_path.write_bytes(encode(manifest))
    except Exception:
        for path, before, after, mode in reversed(written):
            if path.exists() and path.read_bytes() == after:
                if before:
                    atomic_write(path, before, mode)
                else:
                    path.unlink()
        raise
    return [item[1] for item in changes]


def rollback(stack, backup, api=None, check_only=False):
    manifest = json.loads((backup / 'manifest.json').read_text())
    if manifest.get('alert_result_uncertain'):
        raise ValueError('Alert API result uncertain; inspect the AI rule before manual recovery. Dashboard writes were rolled back on failure.')
    if str(stack.resolve()) != manifest['stack']:
        raise ValueError('Backup stack mismatch')
    restored = []
    for entry in manifest['files']:
        relative = entry['path']
        if relative not in PANELS:
            raise ValueError('Unexpected backup path')
        path = stack / 'grafana/dashboards' / relative
        before = (backup / relative).read_bytes()
        if digest(before) != entry['before'] or digest(path.read_bytes()) != entry['after']:
            raise ValueError('Dashboard changed after deployment; review before rollback: ' + relative)
        restored.append((path, before, entry['mode'], entry.get('created', False)))
    if manifest['created_rule']:
        if not api:
            raise ValueError('GRAFANA_TOKEN and --include-ai-alert required to roll back the created alert')
        if api.rule() != manifest['created_rule']:
            raise ValueError('AI alert changed after deployment; refusing to delete it')
    if check_only:
        return {'fingerprint': digest(encode(manifest)), 'dashboard_changes': [e['path'] for e in manifest['files']],
                'ai_alert': 'remove-created-rule' if manifest['created_rule'] else 'unchanged', 'services_restarted': []}
    if manifest['created_rule']:
        api.request('DELETE', '/api/v1/provisioning/alert-rules/' + AI_UID)
    for path, before, mode, created in restored:
        if created:
            path.unlink()
        else:
            atomic_write(path, before, mode)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('mode', choices=['prepare', 'check', 'apply', 'rollback', 'check-rollback', 'verify'])
    parser.add_argument('--bundle', type=Path, required=True)
    parser.add_argument('--target', choices=['all', *TARGETS], default='all')
    parser.add_argument('--stack', type=Path, default=Path('/opt/stockspoon-telemetry'))
    parser.add_argument('--backup', type=Path)
    parser.add_argument('--include-ai-alert', action='store_true')
    parser.add_argument('--verify-grafana', action='store_true')
    parser.add_argument('--expected-plan')
    args = parser.parse_args()
    if args.mode == 'prepare':
        prepare(args.bundle, args.target)
        print('Bundle prepared locally; no deployment performed.')
        return
    api = Grafana('http://127.0.0.1:3000') if args.include_ai_alert or args.verify_grafana else None
    if args.mode == 'verify':
        verify(args.stack, args.bundle, api)
        print('Selected dashboards and alert verified; no services restarted.')
        return
    if args.mode in ('rollback', 'check-rollback'):
        if args.backup and json.loads((args.backup / 'manifest.json').read_text()).get('target') != json.loads((args.bundle / 'patch.json').read_text()).get('target'):
            raise ValueError('Rollback target differs from the backup target')
        if not args.backup:
            parser.error('rollback requires --backup')
        review = rollback(args.stack, args.backup, api, check_only=True)
    else:
        review = inspection(args.stack, args.bundle, api if args.include_ai_alert else None)
    if args.mode in ('check', 'check-rollback'):
        print(json.dumps(review))
        return
    if not args.backup or not args.expected_plan:
        parser.error('apply/rollback require --backup and --expected-plan from check')
    if args.expected_plan != review['fingerprint']:
        raise ValueError('Live configuration changed after review; run check again')
    if args.mode == 'apply':
        updated = apply(args.stack, args.bundle, args.backup, api if args.include_ai_alert else None)
        try:
            verify(args.stack, args.bundle, api)
        except Exception:
            rollback(args.stack, args.backup, api)
            raise
        print(json.dumps({'updated': updated, 'backup': str(args.backup), 'verified': True, 'services_restarted': []}))
    else:
        rollback(args.stack, args.backup, api)
        print('Rollback completed; no services restarted.')


if __name__ == '__main__':
    main()
