import asyncio
import json
import io
from contextlib import redirect_stdout
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

from quote_state import fingerprint
from quote_reference import observe, write_checkpoint, main as reference_main
from quote_report import analyze


def price(**values):
    return {'code': 'Q00000', 'price': 100, 'change': -1, 'rate': 9.876, 'volume': 123,
            'timestamp': '2026-10-29T00:00:00.123456Z', **values}


class QuoteMeasurementTests(unittest.TestCase):
    def test_hash_ignores_json_order_and_timezone_representation(self):
        value = price()
        other = dict(reversed(list(value.items())))
        other['timestamp'] = '2026-10-29T09:00:00.123456+09:00'
        other['price'] = 100.0
        self.assertEqual(fingerprint('prices', value), fingerprint('prices', other))
        self.assertNotEqual(fingerprint('prices', value)['hash'], fingerprint('prices', price(price=101))['hash'])
        self.assertNotEqual(fingerprint('prices', value)['hash'], fingerprint('prices', price(timestamp='2026-10-29T00:00:00.123999Z'))['hash'])
        for extra in ({'rate': float('nan')}, {'sequence': 2**53}, {'price': True}, {'timestamp': '2026-10-29T00:00:00'}):
            with self.assertRaises(ValueError):
                fingerprint('prices', price(**extra))

    def test_explicit_module_path_help_works_in_shallow_container_mount(self):
        with patch('quote_reference.__file__', '/tools/quote_reference.py'), \
             patch('sys.argv', ['quote_reference.py', '--help']), redirect_stdout(io.StringIO()):
            with self.assertRaises(SystemExit) as result:
                reference_main()
            self.assertEqual(result.exception.code, 0)

    def fixture(self):
        state = fingerprint('prices', price())
        checkpoint = {'states': {'prices:Q00000': state}, 'reference': 'independent_pubsub_and_cache',
                      'frozen_at_ms': 100, 'at_ms': 120, 'checkpoint_id': 'c1'}
        plan = {'codes': {'prices': ['Q00000']}, 'connections': 2,
                'groups': {'home_prices': {'connections': 2, 'stream': 'prices', 'code_count': 1}}}
        refs = [{'kind': k, 'at_ms': t} for k, t in [('reference_ready', 0), ('reference_checkpoint', 120), ('reference_finished', 200)]]
        refs[1]['checkpoint_id'] = 'c1'
        events = []
        for cid in ['1', '2']:
            events += [{'kind': 'quote_subscription', 'client_id': cid, 'at_ms': 10, 'stream': 'prices',
                        'group': 'home_prices', 'codes': ['Q00000']},
                       {'kind': 'quote_state', 'client_id': cid, 'at_ms': 190,
                        'states': {'Q00000': {**state, 'since_ms': 150, 'received_ms': 180}},
                        'regressions': 0, 'conflicts': 0}]
        return plan, checkpoint, refs, events

    def test_quiet_code_need_not_advance_and_missing_clients_stay_in_denominator(self):
        p, c, r, e = self.fixture()
        result = analyze(p, c, r, e, 200, 50)
        self.assertEqual(result['status'], 'MEASURED')
        self.assertEqual(result['recovery_rate'], 1)
        self.assertEqual(result['all_codes_recovery']['p99_ms'], 100)
        partial = analyze(p, c, r, e[:2], 200)
        self.assertEqual(partial['status'], 'INCONCLUSIVE')
        self.assertEqual(partial['recovery_rate'], .5)
        self.assertEqual(partial['unrecovered_clients'], 1)

    def test_final_mismatch_stale_sample_reference_gap_and_post_checkpoint_change(self):
        p, c, r, e = self.fixture()
        e[-1]['states']['Q00000']['hash'] = 'wrong'
        e[-1]['regressions'] = 2
        result = analyze(p, c, r, e, 200)
        self.assertEqual(result['missing_client_code_pairs'], 1)
        self.assertEqual(result['regressions'], 2)
        self.assertEqual(result['recovered_clients'], 1)
        self.assertEqual(analyze(p, c, r, e, 30000)['recovered_clients'], 0)
        invalid = r + [{'kind': 'reference_invalid', 'at_ms': 190}]
        self.assertEqual(analyze(p, c, invalid, e, 200)['status'], 'INCONCLUSIVE')
        changed = r + [{'kind': 'reference_quote', 'at_ms': 150, 'key': 'prices:Q00000', 'state': {}}]
        self.assertEqual(analyze(p, c, changed, e, 200)['status'], 'INCONCLUSIVE')

    def test_violation_details_and_suppression_are_preserved_without_counting_after_end(self):
        p, c, r, e = self.fixture()
        for row in e:
            if row['kind'] == 'quote_state':
                row.update(state_rollbacks=1, violation_details_suppressed=3)
        value = fingerprint('prices', price())
        detail = {'kind': 'quote_regression', 'client_id': '1', 'group': 'home_prices',
                  'stream': 'prices', 'attempt': 2, 'at_ms': 180, 'code': 'Q00000',
                  'comparison_field': 'timestamp_key', 'state_rolled_back': True,
                  'previous': {**value, 'received_ms': 170, 'attempt': 1},
                  'high_watermark': value,
                  'received': {**value, 'hash': 'received-hash', 'received_ms': 180,
                               'attempt': 2, 'code_payload_index': 1}}
        conflict = {**detail, 'kind': 'quote_version_conflict', 'at_ms': 185}
        after_end = {**detail, 'at_ms': 201}
        result = analyze(p, c, r, [*e, detail, conflict, after_end], 200)
        self.assertEqual(result['violation_details'], [detail, conflict])
        self.assertEqual(result['state_rollbacks'], 2)
        self.assertEqual(result['violation_details_suppressed'], 6)
        self.assertEqual(result['recovered_clients'], 2)
        legacy = analyze(*self.fixture(), 200)
        self.assertIsNone(legacy['state_rollbacks'])
        self.assertIsNone(legacy['violation_details_suppressed'])
        self.assertEqual(legacy['violation_details'], [])

    def test_missing_observer_or_cache_value_cannot_create_checkpoint(self):
        with tempfile.TemporaryDirectory() as root:
            path = Path(root) / 'checkpoint.json'
            with self.assertRaises(ValueError):
                write_checkpoint(path, {'prices:Q00000': {}}, {}, 'c1', 0, 10)
            self.assertFalse(path.exists())
            write_checkpoint(path, {'prices:Q00000': {}}, {'prices:Q00000': {}}, 'c1', 0, 10)
            with self.assertRaises(FileExistsError):
                write_checkpoint(path, {'prices:Q00000': {}}, {'prices:Q00000': {}}, 'c1', 0, 10)

    def test_reference_stop_before_checkpoint_is_invalid(self):
        from unittest.mock import AsyncMock, MagicMock
        with tempfile.TemporaryDirectory() as root:
            out = Path(root);stop = out / 'stop.request';stop.touch()
            client = MagicMock();client.aclose = AsyncMock()
            sub = MagicMock();sub.subscribe = AsyncMock()
            client.pubsub.return_value.__aenter__ = AsyncMock(return_value=sub)
            client.pubsub.return_value.__aexit__ = AsyncMock(return_value=False)
            with self.assertRaisesRegex(ValueError, 'before a verified checkpoint'):
                asyncio.run(observe(client, {'codes': {'prices': ['Q00000']}}, out,
                                    10, out/'checkpoint-request.json', 1, 100000, stop))
            rows = [json.loads(line) for line in (out/'reference.jsonl').read_text().splitlines()]
            self.assertEqual(rows[-1]['kind'], 'reference_invalid')
            client.aclose.assert_awaited_once()

    def test_independent_subscriber_ack_then_cache_checkpoint_and_gap_detection(self):
        class Client:
            clock = 0
            closed = False
            def __init__(self, reconnect=False, stop_path=None):
                self.stop_path = stop_path
                self.messages = [{'type': 'subscribe', 'channel': c} for c in ['market:prices', 'market:orderbooks']]
                self.messages += [{'type': 'message', 'channel': 'market:prices', 'data': json.dumps(price())}]
                if reconnect:
                    self.messages += [{'type': 'subscribe', 'channel': 'market:prices'}]
            def pubsub(self): return self
            async def __aenter__(self): return self
            async def __aexit__(self, *args): pass
            async def subscribe(self, *args): pass
            async def get_message(self, **kwargs):
                self.clock += 1
                if self.stop_path is not None and self.clock == 6: self.stop_path.touch()
                return self.messages.pop(0) if self.messages else None
            def pipeline(self, transaction):
                assert transaction is False
                self.requested_keys = []
                return self
            def get(self, key): self.requested_keys.append(key)
            async def execute(self):
                assert self.requested_keys == ['price:Q00000']
                return [json.dumps(price())]
            async def mget(self, keys): raise AssertionError('cross-slot MGET must not be used')
            async def aclose(self): self.closed = True
        for reconnect, early_finish in [(False, False), (True, False), (False, True)]:
            with tempfile.TemporaryDirectory() as root:
                out = Path(root)
                request = out / 'request.json'
                request.write_text(json.dumps({'checkpoint_id': 'c1', 'frozen_at_ms': 0}))
                stop = out / 'stop.request' if early_finish else None
                client = Client(reconnect, stop)
                with patch('quote_reference.time.monotonic', side_effect=lambda: client.clock), patch('quote_reference.now_ms', return_value=10000):
                    if reconnect:
                        with self.assertRaises(ValueError):
                            asyncio.run(observe(client, {'codes': {'prices': ['Q00000']}}, out, 10, request, 1, 100000, stop))
                    else:
                        asyncio.run(observe(client, {'codes': {'prices': ['Q00000']}}, out, 10, request, 1, 100000, stop))
                        self.assertEqual(json.loads((out / 'checkpoint.json').read_text())['reference'], 'independent_pubsub_and_cache')
                self.assertTrue(client.closed)
                if early_finish:
                    self.assertLess(client.clock, 10)
                    rows=[json.loads(line) for line in (out/'reference.jsonl').read_text().splitlines()]
                    self.assertEqual(rows[-1]['kind'], 'reference_finished')
                    self.assertTrue(rows[-1]['checkpoint_written'])


if __name__ == '__main__':
    unittest.main()
