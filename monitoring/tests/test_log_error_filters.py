"""Regression coverage for normal request fields mistaken for exceptions."""
import json
from pathlib import Path
import re
import unittest


ROOT = Path(__file__).resolve().parents[1] / 'config/grafana'


class LogErrorFiltersTest(unittest.TestCase):
    def test_error_queries_ignore_exception_type_field_but_keep_real_errors(self):
        checked = 0
        for path in ROOT.rglob('*.json'):
            document = json.loads(path.read_text())
            for query in self.expressions(document):
                # FE and shared dashboards retain their existing search behavior.
                if '|~' not in query or r'exception\\b' not in query:
                    continue
                # Decode the LogQL quoted string as well as the outer JSON.
                match = re.search(r'\|~\s*("(?:\\.|[^"\\])*")', query)
                self.assertIsNotNone(match, str(path))
                pattern = re.compile(json.loads(match.group(1)))
                for line in (
                    'INFO GET /actuator/health status=200 exceptionType=none',
                    '{"level":"INFO","path":"/health","exceptionType":"none"}',
                    'INFO GET /api/stocks status=200 exceptionType=none',
                ):
                    self.assertIsNone(pattern.search(line), (str(path), line))
                for line in (
                    'ERROR GET /actuator/health status=503 exceptionType=none',
                    'exceptionType=java.lang.RuntimeException',
                    'java.io.IOException: connection reset',
                    'Exception: failed',
                    'FATAL startup failed',
                    'error connection refused',
                ):
                    self.assertIsNotNone(pattern.search(line), (str(path), line))
                checked += 1
        self.assertGreater(checked, 0)

    def expressions(self, value):
        if isinstance(value, dict):
            for key, child in value.items():
                if key == 'expr' and isinstance(child, str):
                    yield child
                else:
                    yield from self.expressions(child)
        elif isinstance(value, list):
            for child in value:
                yield from self.expressions(child)
