import crypto from 'k6/crypto';

export function fingerprint(stream, payload) {
  const stamp = Date.parse(payload.timestamp);
  const sequence = payload.sequence === undefined ? null : payload.sequence;
  if (!Number.isFinite(stamp) || !/(Z|[+-]\d\d:\d\d)$/.test(payload.timestamp) ||
      (sequence !== null && (!Number.isSafeInteger(sequence) || sequence < 0))) throw new Error('invalid quote version');
  const fraction = payload.timestamp.match(/\.(\d{1,9})(?=Z|[+-]\d\d:\d\d$)/);
  if (stamp < 0 || (payload.timestamp.includes('.') && !fraction)) throw new Error('unsupported timestamp precision or epoch');
  const timestampKey = String(Math.floor(stamp / 1000)).padStart(12, '0') + (fraction ? fraction[1] : '').padEnd(9, '0');
  function number(value) {
    if (typeof value !== 'number' || !Number.isFinite(value)) throw new Error('finite numeric field required');
    const buffer = new ArrayBuffer(8);
    new DataView(buffer).setFloat64(0, value === 0 ? 0 : value, false);
    return Array.from(new Uint8Array(buffer), x => x.toString(16).padStart(2, '0')).join('');
  }
  let values = [stream, payload.code, timestampKey, sequence === null ? null : String(sequence)];
  if (stream === 'prices') values = values.concat(['price', 'change', 'rate', 'volume'].map(k => number(payload[k])));
  else if (stream === 'orderbooks') values = values.concat(['asks', 'bids'].map(side => payload[side].map(x => [number(x.price), number(x.qty)])));
  else throw new Error('unknown stream');
  return {timestamp_ms: stamp, timestamp_key: timestampKey, sequence, hash: crypto.sha256(JSON.stringify(values), 'hex')};
}

export class QuoteState {
  constructor(stream, emit) {
    this.stream = stream;
    this.emit = emit;
    this.latest = {};
    this.high = {};
    this.regressions = 0;
    this.conflicts = 0;
  }
  accept(payload, now) {
    const value = fingerprint(this.stream, payload), code = payload.code;
    const high = this.high[code], old = this.latest[code];
    let order = 1;
    if (high) {
      if ((value.sequence === null) !== (high.sequence === null)) throw new Error('sequence availability changed');
      const key = value.sequence === null ? 'timestamp_key' : 'sequence';
      order = value[key] < high[key] ? -1 : value[key] > high[key] ? 1 : 0;
      if (order < 0) this.regressions++;
      if (order === 0 && value.hash !== high.hash) this.conflicts++;
    }
    if (!high || order > 0) this.high[code] = value;
    const same = old && old.hash === value.hash && old.timestamp_key === value.timestamp_key && old.sequence === value.sequence;
    this.latest[code] = {...value, since_ms: same ? old.since_ms : now, received_ms: now};
  }
  snapshot(codes, now) {
    this.emit('quote_state', {schema: 1, at_ms: now, codes, states: this.latest,
      regressions: this.regressions, conflicts: this.conflicts});
  }
}
