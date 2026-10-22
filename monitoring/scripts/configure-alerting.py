#!/usr/bin/env python3
"""Configure local Grafana alert provisioning. Does not restart or send notifications."""
from __future__ import annotations

import argparse
import getpass
import json
import os
from pathlib import Path
import re
import subprocess

SECRET = Path('/srv/stockspoon-telemetry/secrets/discord_webhook_url')
STACK = Path('/opt/stockspoon-telemetry')


def render(provisioning: Path, webhook: str | None) -> None:
    rules_path = provisioning / 'rules.json'
    document = json.loads(rules_path.read_text())
    if webhook and not re.fullmatch(r'https://discord\.com/api/webhooks/[0-9]+/[A-Za-z0-9_-]+', webhook):
        raise ValueError('Expected a Discord HTTPS webhook URL')
    if webhook:
        contact = {'apiVersion': 1, 'contactPoints': [{
            'orgId': 1, 'name': 'stockspoon-discord', 'receivers': [{
                'uid': 'stockspoon-discord', 'type': 'discord',
                'disableResolveMessage': False, 'settings': {'url': webhook},
            }],
        }]}
        destination = provisioning / 'discord.local.json'
        destination.write_text(json.dumps(contact, ensure_ascii=False, indent=2) + '\n')
        destination.chmod(0o600)
        if os.geteuid() == 0:
            os.chown(destination, 472, 0)
    for group in document['groups']:
        for rule in group['rules']:
            rule['isPaused'] = not bool(webhook)
            if webhook:
                rule['notification_settings'] = {
                    'receiver': 'stockspoon-discord',
                    'group_by': ['alertname', 'environment', 'cluster'],
                    'group_wait': '30s', 'group_interval': '5m', 'repeat_interval': '4h',
                }
            else:
                rule.pop('notification_settings', None)
    rules_path.write_text(json.dumps(document, ensure_ascii=False, indent=2) + '\n')


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    source = parser.add_mutually_exclusive_group()
    source.add_argument('--configure', action='store_true', help='Prompt for a webhook without echoing it')
    source.add_argument('--existing-channel', action='store_true', help='Read the existing application Discord secret from AWS')
    args = parser.parse_args()
    if args.configure or args.existing_channel:
        if args.existing_channel:
            result = subprocess.run([
                'aws', 'secretsmanager', 'get-secret-value',
                '--region', 'ap-northeast-2',
                '--secret-id', 'stockspoon/v1/app/discord-webhook',
                '--query', 'SecretString', '--output', 'text', '--no-cli-pager',
            ], capture_output=True, text=True)
            if result.returncode:
                raise SystemExit('Cannot read the existing Discord secret; check the instance IAM policy. No configuration changed.')
            webhook = result.stdout.strip()
        else:
            webhook = getpass.getpass('Discord webhook URL: ').strip()
        if not re.fullmatch(r'https://discord\.com/api/webhooks/[0-9]+/[A-Za-z0-9_-]+', webhook):
            raise SystemExit('Invalid Discord webhook URL; no configuration changed')
        SECRET.parent.mkdir(parents=True, exist_ok=True)
        descriptor = os.open(SECRET, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
        with os.fdopen(descriptor, 'w') as stream:
            stream.write(webhook + '\n')
        SECRET.chmod(0o600)
    webhook = SECRET.read_text().strip() if SECRET.exists() else None
    render(STACK / 'grafana/provisioning/alerting', webhook)
    print('Discord alerts enabled.' if webhook else 'Webhook is absent; alert rules remain paused.')
    print('No restart or notification was sent. Restart Grafana to load changes.')


if __name__ == '__main__':
    main()
