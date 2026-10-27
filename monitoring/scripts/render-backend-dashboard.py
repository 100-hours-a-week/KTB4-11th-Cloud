#!/usr/bin/env python3
"""Prepare a dashboard-only SSM payload locally; never submit or restart services."""
import argparse
import base64
import json
from pathlib import Path
import re
import shlex

ROOT = Path(__file__).resolve().parents[1]


def make_payload(instance_id):
    if not re.fullmatch(r'i-[0-9a-f]{8,17}', instance_id):
        raise ValueError('Expected an EC2 instance ID')
    source = ROOT / 'config/grafana/dashboards/prod/backend.json'
    dashboard = json.loads(source.read_text())
    if dashboard['uid'] != 'stockspoon-prod-backend':
        raise ValueError('Unexpected dashboard identity')
    encoded = base64.b64encode(source.read_bytes()).decode()
    command = '\n'.join([
        '#!/bin/bash', 'set -Eeuo pipefail', 'umask 022',
        'directory=/opt/stockspoon-telemetry/grafana/dashboards/prod',
        'test -d "$directory"',
        'backup=$(mktemp -d /opt/stockspoon-backend-dashboard-backup.XXXXXX)',
        'if [[ -f "$directory/backend.json" ]]; then cp -p "$directory/backend.json" "$backup/backend.json"; fi',
        'temporary=$(mktemp "$directory/.backend.XXXXXX")',
        'trap \'rm -f "$temporary"\' EXIT',
        'printf %s ' + shlex.quote(encoded) + ' | base64 -d > "$temporary"',
        'python3 -m json.tool "$temporary" > /dev/null',
        'chmod 0644 "$temporary"',
        'mv "$temporary" "$directory/backend.json"',
        'printf "Dashboard installed; Grafana polls in 30s. Backup: %s\\n" "$backup"',
    ])
    return {'DocumentName': 'AWS-RunShellScript', 'InstanceIds': [instance_id],
            'Comment': 'Update only production backend Grafana dashboard',
            'TimeoutSeconds': 60, 'Parameters': {'commands': [command]}}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--instance-id', required=True)
    parser.add_argument('--output', required=True, type=Path)
    args = parser.parse_args()
    payload = make_payload(args.instance_id)
    args.output.write_text(json.dumps(payload, ensure_ascii=False, indent=2) + '\n')
    args.output.chmod(0o600)
    print(f'Prepared {args.output}; no AWS request submitted.')


if __name__ == '__main__':
    main()
