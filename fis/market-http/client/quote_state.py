import hashlib
import json
import math
import re
import struct
from datetime import datetime, timezone


def fingerprint(stream, payload):
    stamp = datetime.fromisoformat(payload['timestamp'].replace('Z', '+00:00'))
    if stamp.tzinfo is None:
        raise ValueError('timestamp requires timezone')
    epoch = stamp.astimezone(timezone.utc) - datetime(1970, 1, 1, tzinfo=timezone.utc)
    timestamp = epoch.days * 86400000 + epoch.seconds * 1000 + epoch.microseconds // 1000
    fraction = re.search(r'\.(\d{1,9})(?=Z|[+-]\d\d:\d\d$)', payload['timestamp'])
    if timestamp < 0 or ('.' in payload['timestamp'] and fraction is None):
        raise ValueError('unsupported timestamp precision or epoch')
    timestamp_key = str(epoch.days * 86400 + epoch.seconds).zfill(12) + (fraction[1] if fraction else '').ljust(9, '0')
    sequence = payload.get('sequence')
    if sequence is not None and (isinstance(sequence, bool) or not isinstance(sequence, int)
                                 or not 0 <= sequence <= 2**53 - 1):
        raise ValueError('sequence must be a safe nonnegative integer')

    def number(value):
        if isinstance(value, bool) or not isinstance(value, (int, float)) or not math.isfinite(value):
            raise ValueError('finite numeric field required')
        return struct.pack('>d', float(value) if value else 0.0).hex()

    values = [stream, payload['code'], timestamp_key, str(sequence) if sequence is not None else None]
    if stream == 'prices':
        values += [number(payload[k]) for k in ('price', 'change', 'rate', 'volume')]
    elif stream == 'orderbooks':
        values += [[[number(level['price']), number(level['qty'])] for level in payload[side]]
                   for side in ('asks', 'bids')]
    else:
        raise ValueError('unknown stream')
    digest = hashlib.sha256(json.dumps(values, separators=(',', ':'), ensure_ascii=True).encode()).hexdigest()
    return {'timestamp_ms': timestamp, 'timestamp_key': timestamp_key, 'sequence': sequence, 'hash': digest}


def compare_version(current, previous):
    if (current['sequence'] is None) != (previous['sequence'] is None):
        raise ValueError('sequence availability changed')
    key = 'sequence' if current['sequence'] is not None else 'timestamp_key'
    return (current[key] > previous[key]) - (current[key] < previous[key])
