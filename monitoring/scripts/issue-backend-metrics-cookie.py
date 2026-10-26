#!/usr/bin/env python3
"""Issue a local, short-lived access JWT using an SSM signing key; never deploy."""
import argparse
import base64
from datetime import datetime, timezone
import hashlib
import hmac
import json
import os
from pathlib import Path
import secrets
import subprocess
import time
import uuid

ROOT = Path(__file__).resolve().parents[2]


def b64url(value):
    return base64.urlsafe_b64encode(value).rstrip(b'=').decode('ascii')


def issue(secret, issuer, subject, lifetime_seconds=7200, now=None):
    if len(secret.encode('utf-8')) < 32:
        raise ValueError('JWT signing key must contain at least 32 UTF-8 bytes')
    if not issuer or not subject.isdecimal() or not 0 < int(subject) <= 9223372036854775807:
        raise ValueError('Issuer and a positive Java long subject are required')
    if not 1 <= lifetime_seconds <= 259200:
        raise ValueError('Choose an explicit lifetime between 1 second and 72 hours')
    now = int(time.time()) if now is None else now
    claims = {'iss': issuer, 'sub': subject, 'iat': now, 'exp': now + lifetime_seconds,
              'jti': str(uuid.uuid4()), 'type': 'access', 'actor': 'USER'}
    header = {'alg': 'HS256', 'typ': 'JWT'}
    encode = lambda value: b64url(json.dumps(value, separators=(',', ':')).encode('utf-8'))
    unsigned = encode(header) + '.' + encode(claims)
    signature = hmac.new(secret.encode('utf-8'), unsigned.encode('ascii'), hashlib.sha256).digest()
    return unsigned + '.' + b64url(signature), claims


def private_file(path, content):
    descriptor = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    with os.fdopen(descriptor, 'w') as stream:
        stream.write(content)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--profile', default='pattie_for_terraform')
    parser.add_argument('--region', default='ap-northeast-2')
    parser.add_argument('--signing-key-parameter', required=True)
    parser.add_argument('--issuer', required=True, help='Match the deployed issuer; no guessing')
    parser.add_argument('--user-id', help='Existing test user ID; omit for an unverified synthetic subject')
    parser.add_argument('--lifetime-seconds', type=int, default=7200)
    parser.add_argument('--output-dir', required=True, type=Path, help='New private directory outside Git')
    args = parser.parse_args()
    output = args.output_dir.resolve()
    if output.is_relative_to(ROOT) or output.exists():
        parser.error('Use a new directory outside this repository')
    if not 1 <= args.lifetime_seconds <= 259200:
        parser.error('Lifetime must be between 1 second and 72 hours')
    subject = args.user_id or str(secrets.randbelow(2**61) + 2**61)
    if not subject.isdecimal() or not 0 < int(subject) <= 9223372036854775807:
        parser.error('User ID must be a positive Java long')
    # Capture the secret only in memory. Never print stdout/stderr from this call.
    result = subprocess.run(['aws', '--profile', args.profile, '--region', args.region,
                             'ssm', 'get-parameter', '--name', args.signing_key_parameter,
                             '--with-decryption', '--query', 'Parameter.Value', '--output', 'json'],
                            capture_output=True, text=True)
    if result.returncode:
        raise SystemExit('SSM signing-key read failed; check profile and GetParameter/Decrypt permissions')
    try:
        token, claims = issue(json.loads(result.stdout), args.issuer, subject, args.lifetime_seconds)
    except (ValueError, TypeError):
        raise SystemExit('Invalid signing-key response or JWT settings; no credential was printed') from None
    output.mkdir(mode=0o700)
    private_file(output / 'access.jwt', token + '\n')
    private_file(output / 'cookie.txt', 'access_token=' + token + '\n')
    private_file(output / 'ssm-cookie.json', json.dumps({
        'Name': '/stockspoon/v2/prod/telemetry/BACKEND_METRICS_COOKIE',
        'Type': 'SecureString', 'Value': 'access_token=' + token,
        'Description': 'Temporary backend metrics cookie; expires ' + str(claims['exp']),
    }, indent=2) + '\n')
    expires = datetime.fromtimestamp(claims['exp'], timezone.utc).isoformat()
    metadata = {'issuer': args.issuer, 'subject': subject, 'expires_at_utc': expires,
                'database_account_verified': False,
                'synthetic_subject': args.user_id is None,
                'scope_note': 'Ordinary access JWT; backend does not enforce metrics-only scope'}
    private_file(output / 'metadata.json', json.dumps(metadata, indent=2) + '\n')
    print(f'Local files written to {output}; expiry UTC: {expires}')
    print('No DB/API request, SSM write, rollout or Terraform apply performed. Token/key not printed.')


if __name__ == '__main__':
    main()
