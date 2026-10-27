import base64
from contextlib import redirect_stdout
import hashlib
import hmac
import importlib.util
import io
import json
from pathlib import Path
import tempfile
from types import SimpleNamespace
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('issue_metrics_cookie', ROOT / 'scripts/issue-backend-metrics-cookie.py')
issuer = importlib.util.module_from_spec(spec)
spec.loader.exec_module(issuer)


class MetricsCookieTest(unittest.TestCase):
    def test_jwt_matches_existing_backend_claims_and_hs256(self):
        key = 'test-only-signing-key-not-production-1234'
        token, claims = issuer.issue(key, 'stockspoon', '4611686018427387904', 7200, now=1000)
        header, payload, signature = token.split('.')
        decode = lambda s: json.loads(base64.urlsafe_b64decode(s + '=' * (-len(s) % 4)))
        self.assertEqual(decode(header), {'alg': 'HS256', 'typ': 'JWT'})
        self.assertEqual(decode(payload), claims)
        self.assertEqual(claims['type'], 'access')
        self.assertEqual(claims['actor'], 'USER')
        self.assertEqual(claims['exp'] - claims['iat'], 7200)
        signed = base64.urlsafe_b64decode(signature + '=' * (-len(signature) % 4))
        expected = hmac.digest(key.encode(), (header + '.' + payload).encode(), hashlib.sha256)
        self.assertTrue(hmac.compare_digest(signed, expected))
        self.assertNotIn(key, token)

    def test_requested_72_hour_lifetime_is_supported(self):
        _, claims = issuer.issue('x' * 32, 'stockspoon', '1', 259200, now=1000)
        self.assertEqual(claims['exp'] - claims['iat'], 72 * 60 * 60)

    def test_invalid_settings_are_rejected(self):
        key = 'x' * 32
        for seconds in [0, -1, 259201]:
            with self.assertRaises(ValueError):
                issuer.issue(key, 'stockspoon', '1', seconds)
        for subject in ['0', '-1', 'metrics', '9223372036854775808']:
            with self.assertRaises(ValueError):
                issuer.issue(key, 'stockspoon', subject)
        with self.assertRaises(ValueError):
            issuer.issue('short', 'stockspoon', '1')

    def test_local_issuance_only_reads_ssm_and_keeps_credentials_private(self):
        key = 'test-only-signing-key-not-production-1234'
        with tempfile.TemporaryDirectory() as directory:
            output = Path(directory) / 'credentials'
            args = ['issue-backend-metrics-cookie.py', '--signing-key-parameter', '/example/JWT_SECRET',
                    '--issuer', 'stockspoon', '--output-dir', str(output)]
            log = io.StringIO()
            with patch('sys.argv', args), patch.object(issuer.subprocess, 'run', return_value=SimpleNamespace(
                    returncode=0, stdout=json.dumps(key))) as run, redirect_stdout(log):
                issuer.main()
            run.assert_called_once()
            self.assertIn('get-parameter', run.call_args.args[0])
            self.assertNotIn('put-parameter', run.call_args.args[0])
            token = (output / 'access.jwt').read_text().strip()
            self.assertNotIn(token, log.getvalue())
            self.assertNotIn(key, log.getvalue())
            self.assertEqual(output.stat().st_mode & 0o777, 0o700)
            for file in output.iterdir():
                self.assertEqual(file.stat().st_mode & 0o777, 0o600)
                self.assertNotIn(key, file.read_text())
            cookie = json.loads((output / 'ssm-cookie.json').read_text())
            self.assertEqual(cookie['Value'], 'access_token=' + token)
            self.assertNotIn('Overwrite', cookie)
            meta = json.loads((output / 'metadata.json').read_text())
            self.assertFalse(meta['database_account_verified'])
            self.assertTrue(meta['synthetic_subject'])


if __name__ == '__main__':
    unittest.main()
