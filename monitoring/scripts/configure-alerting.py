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
DEV_APP_SECRET = Path('/srv/stockspoon-telemetry/secrets/discord_dev_app_webhook_url')
DEV_AI_SECRET = Path('/srv/stockspoon-telemetry/secrets/discord_dev_ai_webhook_url')
STACK = Path('/opt/stockspoon-telemetry')
DEV_PARAMETERS = {role: '/stockspoon/monitoring/dev/' + role + '/discord-webhook' for role in ['app', 'ai']}
RECEIVERS = {'prod': 'stockspoon-discord', 'dev-app': 'stockspoon-discord-dev-app', 'dev-ai': 'stockspoon-discord-dev-ai'}

PROD_COMPONENTS = ('market-http', 'be', 'fe', 'alb')
PROD_PARAMETERS = {component: '/stockspoon/monitoring/prod/' + component + '/discord-webhook' for component in PROD_COMPONENTS}
PROD_SECRETS = {component: Path('/srv/stockspoon-telemetry/secrets/discord_prod_' + component + '_webhook_url') for component in PROD_COMPONENTS}
RECEIVERS.update({'prod-' + component: 'stockspoon-discord-prod-' + component for component in PROD_COMPONENTS})


def validate_webhooks(webhooks: dict[str, str | None]) -> None:
    for webhook in webhooks.values():
        if webhook and not re.fullmatch(r'https://discord\.com/api/webhooks/[0-9]+/[A-Za-z0-9_-]+', webhook):
            raise ValueError('Expected a Discord HTTPS webhook URL')
    configured = [value for value in webhooks.values() if value]
    if len(configured) != len(set(configured)):
        raise ValueError('Each alert channel must use a different Discord webhook')


def render(provisioning: Path, webhook: str | None, dev_app_webhook: str | None = None, dev_ai_webhook: str | None = None, production_webhooks: dict[str, str | None] | None = None) -> None:
    webhooks = {'prod': webhook, 'dev-app': dev_app_webhook, 'dev-ai': dev_ai_webhook}
    production_webhooks = production_webhooks or {}
    if set(production_webhooks) - set(PROD_COMPONENTS):
        raise ValueError('Unknown production component')
    webhooks.update({'prod-' + component: production_webhooks.get(component) for component in PROD_COMPONENTS})
    validate_webhooks(webhooks)
    documents = {}
    for rules_path in sorted(provisioning.glob('*rules.json')):
        document = json.loads(rules_path.read_text())
        for group in document['groups']:
            for rule in group['rules']:
                environment = rule.get('labels', {}).get('environment')
                route = environment
                if environment == 'dev':
                    route = 'dev-' + rule.get('labels', {}).get('host_role', '')
                elif environment == 'prod' and rule.get('labels', {}).get('component'):
                    route = 'prod-' + rule['labels']['component']
                if route not in RECEIVERS:
                    raise ValueError('Every alert rule must select prod or a development App/AI host_role')
                rule['isPaused'] = not bool(webhooks[route])
                if webhooks[route]:
                    rule['notification_settings'] = {
                        'receiver': RECEIVERS[route],
                        'group_by': ['alertname', 'environment', 'component', 'host_role', 'cluster'],
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
        parameter = DEV_PARAMETERS[environment.removeprefix('dev-')] if environment.startswith('dev-') else PROD_PARAMETERS[environment.removeprefix('prod-')]
        arguments = ['ssm', 'get-parameter', '--name', parameter,
                     '--with-decryption', '--query', 'Parameter.Value']
    result = subprocess.run(
        ['aws', *arguments, '--region', 'ap-northeast-2', '--output', 'text', '--no-cli-pager'],
        capture_output=True, text=True,
    )
    if result.returncode:
        raise SystemExit(f'Cannot read the {environment} Discord webhook from AWS; check the parameter/secret and instance IAM policy. No configuration changed.')
    value = result.stdout.strip()
    if environment != 'prod' and value == 'UNCONFIGURED':
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
    parser.add_argument('--host-role', choices=['app', 'ai'])
    parser.add_argument('--component', choices=PROD_COMPONENTS)
    source = parser.add_mutually_exclusive_group()
    source.add_argument('--configure', action='store_true', help='Prompt for a webhook without echoing it')
    source.add_argument('--existing-channel', action='store_true', help='Read the existing production application Discord secret from AWS')
    source.add_argument('--sync-aws', action='store_true', help='Refresh production from Secrets Manager and development from SSM')
    args = parser.parse_args()
    if args.existing_channel and (args.environment != 'prod' or args.component):
        parser.error('--existing-channel is production-only; configure a separate development webhook')
    if args.environment == 'dev' and not args.sync_aws and args.host_role is None:
        parser.error('Select --host-role app or ai for development configuration')
    if args.component and args.environment != 'prod':
        parser.error('--component is production-only')
    selected_route = 'prod' if args.environment == 'prod' else 'dev-' + (args.host_role or 'app')
    if args.environment == 'prod' and args.component:
        selected_route = 'prod-' + args.component
    secrets = {'prod': SECRET, 'dev-app': DEV_APP_SECRET, 'dev-ai': DEV_AI_SECRET}
    secrets.update({'prod-' + component: path for component, path in PROD_SECRETS.items()})
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
        webhooks[selected_route] = webhook
        changed_environments = [selected_route]
    validate_webhooks(webhooks)
    render(STACK / 'grafana/provisioning/alerting', webhooks['prod'], webhooks['dev-app'], webhooks['dev-ai'],
           {component: webhooks['prod-' + component] for component in PROD_COMPONENTS})
    for environment in changed_environments:
        save_secret(secrets[environment], webhooks[environment])
    for environment, value in webhooks.items():
        print(f'{environment}: Discord alerts enabled.' if value else f'{environment}: webhook is absent; alert rules remain paused.')
    print('No restart or notification was sent. Restart Grafana to load changes.')


if __name__ == '__main__':
    main()
