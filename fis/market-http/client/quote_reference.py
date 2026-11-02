import argparse
import asyncio
import json
import os
from pathlib import Path
import sys
import time

from quote_state import fingerprint

CHANNELS = {'market:prices': 'prices', 'market:orderbooks': 'orderbooks'}


def now_ms():
    return time.time_ns() // 1000000


def write_checkpoint(path, latest, cached, checkpoint_id, frozen_at_ms, at_ms):
    if not latest or set(latest) != set(cached) or any(latest[k] != cached[k] for k in latest):
        raise ValueError('independent subscriber and Redis cache disagree or have missing codes')
    result = {'schema': 1, 'checkpoint_id': checkpoint_id, 'frozen_at_ms': frozen_at_ms,
              'at_ms': at_ms, 'states': latest, 'reference': 'independent_pubsub_and_cache'}
    with path.open('x') as out:
        json.dump(result, out, separators=(',', ':'))
    return result


async def observe(client, plan, output, seconds, request_path, quiet_seconds, max_bytes, stop_path=None):
    keys = {stream + ':' + code for stream, codes in plan['codes'].items() for code in codes}
    latest = {}
    ready = False
    pending = set(CHANNELS)
    ended = time.monotonic() + seconds
    last_quote = time.monotonic()
    checkpoint = None
    with (output / 'reference.jsonl').open('x', buffering=1) as log:
        def emit(kind, **fields):
            line = json.dumps({'kind': kind, 'at_ms': now_ms(), **fields}, separators=(',', ':')) + '\n'
            if log.tell() + len(line.encode()) > max_bytes:
                raise ValueError('reference byte budget exhausted')
            log.write(line)
        try:
            async with client.pubsub() as sub:
                await sub.subscribe(*CHANNELS)
                while time.monotonic() < ended:
                    if stop_path is not None and stop_path.exists():
                        if checkpoint is None:
                            raise ValueError('stop requested before a verified checkpoint')
                        break
                    event = await sub.get_message(ignore_subscribe_messages=False, timeout=0.25)
                    if event and event['type'] == 'subscribe':
                        if ready:
                            raise ValueError('reference reconnected; subscription gap possible')
                        pending.discard(event['channel'])
                        if not pending:
                            ready = True
                            emit('reference_ready', keys=sorted(keys))
                    elif event and event['type'] == 'message':
                        if not ready:
                            raise ValueError('message before all subscribe acknowledgements')
                        stream = CHANNELS[event['channel']]
                        payload = json.loads(event['data'])
                        key = stream + ':' + payload['code']
                        if key in keys:
                            value = fingerprint(stream, payload)
                            latest[key] = value
                            last_quote = time.monotonic()
                            emit('reference_quote', key=key, state=value)
                    if ready and checkpoint is None and request_path.exists():
                        request = json.loads(request_path.read_text())
                        frozen = request['frozen_at_ms']
                        if not isinstance(frozen, int) or frozen > now_ms():
                            raise ValueError('invalid frozen_at_ms')
                        if (not event and time.monotonic() - last_quote >= quiet_seconds
                                and now_ms() >= frozen + quiet_seconds * 1000):
                            ordered = sorted(keys)
                            async with client.pipeline(transaction=False) as pipe:
                                for key in ordered:
                                    prefix = 'price' if key.startswith('prices:') else 'orderbook'
                                    pipe.get(prefix + ':' + key.split(':', 1)[1])
                                raw = await pipe.execute()
                            cached = {key: fingerprint(key.split(':', 1)[0], json.loads(value))
                                      for key, value in zip(ordered, raw) if value is not None}
                            if set(latest) == keys and latest == cached:
                                checkpoint = write_checkpoint(output / 'checkpoint.json', dict(latest), cached,
                                                              request['checkpoint_id'], frozen, now_ms())
                                emit('reference_checkpoint', checkpoint_id=request['checkpoint_id'])
                if not ready:
                    raise ValueError('reference never became ready')
                emit('reference_finished', checkpoint_written=checkpoint is not None)
        except BaseException as error:
            try:
                emit('reference_invalid', error_type=type(error).__name__)
            except ValueError:
                pass
            raise
        finally:
            await client.aclose()


def main():
    os.umask(0o077)
    p = argparse.ArgumentParser(description='Read-only independent quote observer; never publishes or injects faults')
    p.add_argument('--plan', type=Path, required=True)
    p.add_argument('--output', type=Path, required=True)
    p.add_argument('--checkpoint-request', type=Path, required=True)
    p.add_argument('--stop-request', type=Path, help='Finish normally only after a verified checkpoint')
    p.add_argument('--seconds', type=int, default=1500)
    p.add_argument('--quiet-seconds', type=float, default=2)
    p.add_argument('--max-mb', type=int, default=256)
    p.add_argument('--publisher-module-dir', type=Path)
    args = p.parse_args()
    if not 1 <= args.seconds <= 7200 or not 1 <= args.quiet_seconds <= 30 or not 1 <= args.max_mb <= 512:
        p.error('invalid finite collection limits')
    from model import validate_plan
    plan = json.loads(args.plan.read_text())
    validate_plan(plan)
    module_dir = args.publisher_module_dir
    if module_dir is None:
        module_dir = Path(__file__).resolve().parents[3] / 'loadtest/test-streamer'
    sys.path.insert(0, str(module_dir.resolve()))
    from mock_publisher import connect_valkey, parse_args
    client = connect_valkey(parse_args([]))
    args.output.mkdir(parents=True, exist_ok=False)
    asyncio.run(observe(client, plan, args.output, args.seconds, args.checkpoint_request,
                        args.quiet_seconds, args.max_mb * 1024**2, args.stop_request))


if __name__ == '__main__':
    main()
