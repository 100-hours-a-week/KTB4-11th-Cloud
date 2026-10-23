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

# Preserve the already configured production credential and receiver.
SECRET = Path('/srv/stockspoon-telemetry/secrets/discord_webhook_url')
DEV_SECRET = Path('/srv/stockspoon-telemetry/secrets/discord_dev_webhook_url')
STACK = Path('/opt/stockspoon-telemetry')
DEV_PARAMETER = '/stockspoon/monitoring/dev/discord-webhook'
RECEIVERS = {'prod': 'stockspoon-discord', 'dev': 'stockspoon-discord-dev'}


def validate_webhooks(webhooks: dict[str, str | None]) -> None:
    for webhook in webhooks.values():
        if webhook and not re.fullmatch(r'https://discord\.com/api/webhooks/[0-9]+/[A-Za-z0-9_-]+', webhook):
            raise ValueError('Expected a Discord HTTPS webhook URL')
    if webhooks.get('prod') and webhooks.get('prod') == webhooks.get('dev'):
        raise ValueError('Development and production must use different Discord webhooks')


def render(provisioning: Path, webhook: str | None, dev_webhook: str | None = None) -> None:
    webhooks = {'prod': webhook, 'dev': dev_webhook}
    validate_webhooks(webhooks)
    documents = {}
    for rules_path in sorted(provisioning.glob('*rules.json')):
        document = json.loads(rules_path.read_text())
        for group in document['groups']:
            for rule in group['rules']:
                environment = rule.get('labels', {}).get('environment')
                if environment not in RECEIVERS:
                    raise ValueError('Every alert rule must explicitly select dev or prod')
                rule['isPaused'] = not bool(webhooks[environment])
                if webhooks[environment]:
                    rule['notification_settings'] = {
                        'receiver': RECEIVERS[environment],
                        'group_by': ['alertname', 'environment', 'cluster'],
                        'group_wait': '30s', 'group_interval': '5m', 'repeat_interval': '4h',
                    }
                else:
                    rule.pop('notification_settings', None)
        documents[rules_path] = document
    if not documents:
        raise ValueError('No alert rule files found; deploy configuration first')
    contacts = [{
        'orgId': 1, 'name': RECEIVERS[environment], 'receivers': [{
            'uid': RECEIVERS[environment], 'type': 'discord',
            'disableResolveMessage': False, 'settings': {'url': value},
        }],
    } for environment, value in webhooks.items() if value]
    if contacts:
        destination = provisioning / 'discord.local.json'
        destination.write_text(json.dumps({'apiVersion': 1, 'contactPoints': contacts}, ensure_ascii=False, indent=2) + '\n')
        destination.chmod(0o600)
        if os.geteuid() == 0:
            os.chown(destination, 472, 0)
    for path, document in documents.items():
        path.write_text(json.dumps(document, ensure_ascii=False, indent=2) + '\n')


def read_secret(path: Path) -> str | None:
    return path.read_text().strip() if path.exists() else None


def read_aws_webhook(environment: str) -> str | None:
    if environment == 'prod':
        arguments = ['secretsmanager', 'get-secret-value',
                     '--secret-id', 'stockspoon/v1/app/discord-webhook',
                     '--query', 'SecretString']
    else:
        arguments = ['ssm', 'get-parameter', '--name', DEV_PARAMETER,
                     '--with-decryption', '--query', 'Parameter.Value']
    result = subprocess.run(
        ['aws', *arguments, '--region', 'ap-northeast-2', '--output', 'text', '--no-cli-pager'],
        capture_output=True, text=True,
    )
    if result.returncode:
        raise SystemExit(f'Cannot read the {environment} Discord webhook from AWS; check the parameter/secret and instance IAM policy. No configuration changed.')
    value = result.stdout.strip()
    if environment == 'dev' and value == 'UNCONFIGURED':
        return None
    if not value:
        raise SystemExit(f'Empty {environment} webhook from AWS; no configuration changed')
    return value


def save_secret(path: Path, value: str | None) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    descriptor = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    with os.fdopen(descriptor, 'w') as stream:
        stream.write((value or '') + '\n')
    path.chmod(0o600)


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--environment', choices=['prod', 'dev'], default='prod')
    source = parser.add_mutually_exclusive_group()
    source.add_argument('--configure', action='store_true', help='Prompt for a webhook without echoing it')
    source.add_argument('--existing-channel', action='store_true', help='Read the existing production application Discord secret from AWS')
    source.add_argument('--sync-aws', action='store_true', help='Refresh production from Secrets Manager and development from SSM')
    args = parser.parse_args()
    if args.existing_channel and args.environment != 'prod':
        parser.error('--existing-channel is production-only; configure a separate development webhook')
    secrets = {'prod': SECRET, 'dev': DEV_SECRET}
    webhooks = {environment: read_secret(path) for environment, path in secrets.items()}
    changed_environments = []
    if args.sync_aws:
        webhooks = {environment: read_aws_webhook(environment) for environment in secrets}
        changed_environments = list(secrets)
    elif args.configure or args.existing_channel:
        if args.existing_channel:
            webhook = read_aws_webhook('prod')
        else:
            webhook = getpass.getpass(f'Discord webhook URL ({args.environment}): ').strip()
        if not webhook:
            raise SystemExit('Empty Discord webhook URL; no configuration changed')
        webhooks[args.environment] = webhook
        changed_environments = [args.environment]
    validate_webhooks(webhooks)
    render(STACK / 'grafana/provisioning/alerting', webhooks['prod'], webhooks['dev'])
    for environment in changed_environments:
        save_secret(secrets[environment], webhooks[environment])
    for environment, value in webhooks.items():
        print(f'{environment}: Discord alerts enabled.' if value else f'{environment}: webhook is absent; alert rules remain paused.')
    print('No restart or notification was sent. Restart Grafana to load changes.')


if __name__ == '__main__':
    main()
