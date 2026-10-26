#!/usr/bin/env python3
"""Migrate only ai-v1 host alerts; leaves CloudWatch deletion to a reviewed Terraform plan."""
import argparse
import base64
import copy
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess
import urllib.error
import urllib.parse
import urllib.request

ROOT = Path(__file__).resolve().parents[1]
SOURCE = ROOT / 'alerts/ai-host-migration.json'
UIDS = {'stockspoon-ai-host-cpu', 'stockspoon-ai-host-memory', 'stockspoon-ai-host-disk', 'stockspoon-prod-ai-metrics-missing'}
RECEIVER = 'stockspoon-discord-ai-host'
GROUP = 'stockspoon-prod-ai-host'


def encoded(value):
    return (json.dumps(value, ensure_ascii=False, indent=2) + '\n').encode()


def fingerprint(value):
    return hashlib.sha256(json.dumps(value, sort_keys=True).encode()).hexdigest()


def load_source(path):
    doc = json.loads(path.read_text())
    if doc['group'] != GROUP or doc['receiver'] != RECEIVER or doc['secret_id'] != 'stockspoon/v1/ai/discord-webhook':
        raise ValueError('Unexpected AI migration identity')
    if {r['uid'] for r in doc['rules']} != UIDS or len(doc['rules']) != len(UIDS):
        raise ValueError('Only the four AI host rules are allowed')
    for r in doc['rules']:
        expr = r['data'][0]['model']['expr']
        if 'cluster="stockspoon-v1-ai"' not in expr or 'host_role="ai"' not in expr or 'environment="prod"' not in expr:
            raise ValueError('Every rule must select only production ai-v1')
        if r['notification_settings']['receiver'] != RECEIVER or r['isPaused'] is not False:
            raise ValueError('Unexpected receiver or pause state')
    return doc


class API:
    def __init__(self):
        password = Path('/srv/stockspoon-telemetry/secrets/grafana_admin_password').read_text().strip()
        self.authorization = 'Basic ' + base64.b64encode(('admin:' + password).encode()).decode()

    def request(self, method, path, body=None):
        req = urllib.request.Request('http://127.0.0.1:3000' + path, method=method,
              headers={'Authorization': self.authorization, 'Content-Type': 'application/json'},
              data=encoded(body) if body is not None else None)
        try:
            with urllib.request.urlopen(req, timeout=30) as result:
                raw = result.read()
                return json.loads(raw) if raw else None
        except urllib.error.HTTPError as error:
            if method == 'GET' and error.code == 404:
                return None
            raise RuntimeError('Grafana API returned HTTP ' + str(error.code)) from None


def overview(api, source):
    rules = api.request('GET', '/api/v1/provisioning/alert-rules')
    folders = api.request('GET', '/api/folders?limit=1000')
    folder = [f['uid'] for f in folders if f['title'] == source['folder']]
    if len(folder) != 1:
        raise ValueError('Expected one existing AI alert folder')
    grouped = [r for r in rules if r.get('folderUID') == folder[0] and r.get('ruleGroup') == GROUP]
    if any(r['uid'] not in UIDS for r in grouped):
        raise ValueError('AI group contains rules outside this migration')
    if any(r.get('provenance') == 'file' for r in grouped):
        raise ValueError('AI rules are still file-provisioned; migrate ownership first')
    contacts = api.request('GET', '/api/v1/provisioning/contact-points')
    owned = [c for c in contacts if c['name'] == RECEIVER]
    if owned and (len(owned) != 1 or owned[0]['uid'] != RECEIVER or owned[0]['type'] != 'discord'):
        raise ValueError('AI contact point name is already in use')
    protected = {'rules': [r for r in rules if r['uid'] not in UIDS],
                 'contacts': [c for c in contacts if c['name'] != RECEIVER]}
    return {'folder': folder[0], 'rules': grouped, 'contacts': owned,
            'protected_sha256': fingerprint(protected)}


def secret():
    command = ['aws', 'secretsmanager', 'get-secret-value', '--region', 'ap-northeast-2',
               '--secret-id', 'stockspoon/v1/ai/discord-webhook', '--query', 'SecretString', '--output', 'text']
    result = subprocess.run(command, capture_output=True, text=True, timeout=30)
    if result.returncode:
        raise ValueError('Cannot read existing AI webhook; apply reviewed monitoring IAM change first')
    value = result.stdout.strip()
    if not re.fullmatch(r'https://discord\.com/api/webhooks/[0-9]+/[A-Za-z0-9_-]+', value):
        raise ValueError('Existing AI secret is not a Discord webhook URL')
    return value


def query_health(source):
    result = {}
    for rule in source['rules']:
        query = rule['data'][0]['model']['expr']
        url = 'http://127.0.0.1:9090/api/v1/query?' + urllib.parse.urlencode({'query': query})
        with urllib.request.urlopen(url, timeout=30) as response:
            doc = json.load(response)
        samples = doc.get('data', {}).get('result', [])
        if doc.get('status') != 'success' or not samples:
            raise ValueError('Missing Prometheus data for ' + rule['uid'])
        result[rule['uid']] = [x['value'][1] for x in samples]
    return result


def apply(api, source, backup, expected):
    before = overview(api, source)
    digest = fingerprint({'source': source, 'live': before})
    if digest != expected:
        raise ValueError('Live alert configuration changed after review')
    query_health(source)
    webhook = secret()  # Validate before changing rules or contacts.
    backup.mkdir(parents=True, mode=0o700, exist_ok=False)
    (backup / 'source.json').write_bytes(encoded(source))
    (backup / 'before.json').write_bytes(encoded(before))
    for p in backup.iterdir():
        p.chmod(0o600)
    group_path = '/api/v1/provisioning/folder/' + before['folder'] + '/rule-groups/' + GROUP
    # Back up the exact group before writes, including interval and pause state.
    original_group = api.request('GET', group_path)
    (backup / 'group-before.json').write_bytes(encoded(original_group))
    (backup / 'group-before.json').chmod(0o600)
    created_contact = not before['contacts']
    if created_contact:
        api.request('POST', '/api/v1/provisioning/contact-points', {'uid': RECEIVER, 'name': RECEIVER,
            'type': 'discord', 'disableResolveMessage': False, 'settings': {'url': webhook}})
    rules = copy.deepcopy(source['rules'])
    for r in rules:
        r['folderUID'] = before['folder']
    try:
        api.request('PUT', group_path, {'title': GROUP, 'folderUid': before['folder'], 'interval': source['interval'], 'rules': rules})
        after = overview(api, source)
        if after['protected_sha256'] != before['protected_sha256']:
            raise ValueError('Unrelated Grafana configuration changed; investigate before CloudWatch deletion')
        verify_rules(after, source)
    except Exception:
        if original_group:
            api.request('PUT', group_path, original_group)
        else:
            api.request('DELETE', group_path)
        # Retain the dedicated contact point on uncertain API results; never delete other receivers.
        raise
    (backup / 'applied.json').write_bytes(encoded({'source_sha256': fingerprint(source), 'protected_sha256': after['protected_sha256'], 'created_contact': created_contact}))
    (backup / 'applied.json').chmod(0o600)
    return {'rules': sorted(UIDS), 'receiver': RECEIVER, 'protected_unchanged': True, 'backup': str(backup)}


def verify_rules(state, source):
    rules = {r['uid']: r for r in state['rules']}
    if set(rules) != UIDS:
        raise ValueError('AI rule set incomplete')
    for wanted in source['rules']:
        live = rules[wanted['uid']]
        if live.get('isPaused') or live.get('notification_settings', {}).get('receiver') != RECEIVER:
            raise ValueError('AI rule paused or incorrectly routed')
        if live['data'][0]['model']['expr'] != wanted['data'][0]['model']['expr']:
            raise ValueError('AI rule query differs from source')
    if not state['contacts']:
        raise ValueError('Dedicated AI contact point missing')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('mode', choices=['check', 'apply', 'verify'])
    parser.add_argument('--source', type=Path, default=SOURCE)
    parser.add_argument('--backup', type=Path)
    parser.add_argument('--expected-plan')
    args = parser.parse_args()
    source = load_source(args.source)
    api = API()
    if args.mode == 'check':
        state = overview(api, source)
        print(json.dumps({'fingerprint': fingerprint({'source': source, 'live': state}),
              'existing_ai_rule_uids': [r['uid'] for r in state['rules']],
              'query_values': query_health(source), 'cloudwatch_alarms': source['cloudwatch_alarms']}))
    elif args.mode == 'apply':
        if not args.backup or not args.expected_plan:
            parser.error('apply requires --backup and --expected-plan')
        print(json.dumps(apply(api, source, args.backup, args.expected_plan)))
    else:
        state = overview(api, source)
        verify_rules(state, source)
        print(json.dumps({'verified': True, 'query_values': query_health(source), 'protected_sha256': state['protected_sha256']}))


if __name__ == '__main__':
    main()
