"""Initialize collector secrets without printing values or overwriting parameters."""

import argparse
import json
import os
from pathlib import Path
import secrets
import subprocess
import tempfile


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--profile', default='stockspoon')
    parser.add_argument('--ssh-key', required=True)
    args = parser.parse_args()
    aws = ['aws', '--profile', args.profile, '--region', 'ap-northeast-2']
    source = subprocess.run(
        ['ssh', '-i', args.ssh_key, '-o', 'BatchMode=yes', '-o', 'ConnectTimeout=10',
         'ubuntu@ec2-15-164-87-85.ap-northeast-2.compute.amazonaws.com',
         'sudo docker inspect backend'], capture_output=True, text=True, check=True,
    )
    container = json.loads(source.stdout)[0]
    environment = dict(item.split('=', 1) for item in container['Config']['Env'] if '=' in item)
    if not container['Config']['Image'].startswith('public.ecr.aws/g8x9p1p0/stockspoon-v1-backend@sha256:'):
        raise RuntimeError('Unexpected source backend image')
    desired = {
        '/stockspoon/v2/prod/backend-collector/KIWOOM_APP_KEY': environment['KIWOOM_APP_KEY'],
        '/stockspoon/v2/prod/backend-collector/KIWOOM_APP_SECRET': environment['KIWOOM_APP_SECRET'],
        '/stockspoon/v2/prod/backend/KIWOOM_COLLECTOR_SECRET': secrets.token_urlsafe(48),
    }
    if not all(value.strip() for value in desired.values()):
        raise RuntimeError('Source credentials must not be empty')
    existing = subprocess.run(
        aws + ['ssm', 'describe-parameters', '--parameter-filters',
               'Key=Name,Option=BeginsWith,Values=/stockspoon/v2/prod/', '--output', 'json'],
        capture_output=True, text=True, check=True,
    )
    names = {item['Name'] for item in json.loads(existing.stdout)['Parameters']}
    for name, value in desired.items():
        if name in names:
            print(json.dumps({'parameter': name, 'action': 'preserved-existing'}))
            continue
        payload = {'Name': name, 'Value': value, 'Type': 'SecureString', 'Overwrite': False,
                   'Tags': [{'Key': 'Project', 'Value': 'stockspoon'},
                            {'Key': 'Purpose', 'Value': 'backend-rest-collector'}]}
        descriptor, filename = tempfile.mkstemp(prefix='stockspoon-collector-', suffix='.json')
        try:
            with os.fdopen(descriptor, 'w') as stream:
                json.dump(payload, stream)
            result = subprocess.run(aws + ['ssm', 'put-parameter', '--cli-input-json', 'file://' + filename],
                                    capture_output=True, text=True)
            if result.returncode:
                raise RuntimeError('Could not initialize parameter: ' + name)
            print(json.dumps({'parameter': name, 'action': 'created-secure-string'}))
        finally:
            Path(filename).unlink(missing_ok=True)


if __name__ == '__main__':
    main()
