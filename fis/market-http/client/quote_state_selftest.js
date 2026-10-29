import {fingerprint, QuoteState, MAX_VIOLATION_DETAILS} from './quote_state.js';
const fixtures = JSON.parse(open('./quote-fixtures.json'));
export const options = {vus: 1, iterations: 1};
function equal(a, b) {if (JSON.stringify(a) !== JSON.stringify(b)) throw new Error(JSON.stringify({a, b}));}
export default function() {
  for (const f of fixtures) equal(fingerprint(f.stream, f.payload), f.expected);
  // Python struct-based oracle: scratch-buffer reuse must preserve all IEEE-754 bits.
  for (const vector of [{"value":0.0,"hash":"ec3d9fb9735d944f1107512f423933fb7928d9a981584b5853103e2424b2a157"},{"value":-0.0,"hash":"ec3d9fb9735d944f1107512f423933fb7928d9a981584b5853103e2424b2a157"},{"value":5e-324,"hash":"e79789ccfe0702305bf194963c242eb298f8afc6aa6d474ce6bd80c3236dd4fa"},{"value":1.7976931348623157e+308,"hash":"fe3df17947d78905a76700714129997d5a557fdf561cf3e1ebdc1ee767c32093"},{"value":2.220446049250313e-16,"hash":"01f8363ffdd00d364e1cc3bd8e130501a310a7a32863dd09408364725fa1bf40"},{"value":-123.5,"hash":"c05e7ded24ac3a514e1ca34480c39dcbd4b9d7aefc10ea22a388207967b96e3b"},{"value":1e-300,"hash":"9901dc4d3acc732e5f066e9ef278279d2267a4afbc753bcee3c36a44f2c99270"},{"value":1e+300,"hash":"b6b19818c40bc6d9d70cd1308cee403c59f1d9177c079eac7f11b6506452f07d"}]) {
    equal(fingerprint('prices', {...fixtures[0].payload, price: vector.value}).hash, vector.hash);
  }
  const events = [], tracker = new QuoteState('prices', (kind, row) => events.push({kind, ...row}));
  const payload = fixtures[0].payload;
  const context = {attempt: 1, session_started_ms: 1, session_headers_ms: 2,
    session_connected_ms: 10, session_payload_index: 1, code_payload_index: 1, event_name: 'price'};
  tracker.accept(payload, 10, context);
  tracker.accept({...payload, price: 101}, 20, {...context, session_payload_index: 2, code_payload_index: 2});
  const older = {...payload, timestamp: '2026-10-29T00:00:00.123456788Z'};
  tracker.accept(older, 30, {...context, attempt: 2, session_payload_index: 1, code_payload_index: 1});
  tracker.snapshot([payload.code], 40);
  const conflict = events[0], regression = events[1], snapshot = events[2];
  equal(conflict.kind, 'quote_version_conflict');
  equal(conflict.previous.hash, fingerprint('prices', payload).hash);
  equal(conflict.received.hash, fingerprint('prices', {...payload, price: 101}).hash);
  equal(regression.kind, 'quote_regression');
  equal(regression.code, payload.code);
  equal(regression.comparison_field, 'timestamp_key');
  equal(regression.previous.source_timestamp, payload.timestamp);
  equal(regression.previous.received_ms, 20);
  equal(regression.previous.hash, conflict.received.hash);
  equal(regression.high_watermark.hash, fingerprint('prices', payload).hash);
  equal(regression.received.source_timestamp, older.timestamp);
  equal(regression.received.hash, fingerprint('prices', older).hash);
  equal(regression.received.received_ms, 30);
  equal(regression.previous.attempt, 1);
  equal(regression.received.attempt, 2);
  equal(regression.received.code_payload_index, 1);
  equal(regression.received.event_name, 'price');
  equal(regression.state_rolled_back, true);
  equal(snapshot.regressions, 1);
  equal(snapshot.conflicts, 1);
  equal(snapshot.state_rollbacks, 1);
  equal(snapshot.violation_details_emitted, 2);
  equal(snapshot.states[payload.code].since_ms, 30);
  tracker.accept(payload, 50);
  tracker.accept(payload, 60);
  equal(tracker.latest[payload.code].since_ms, 50);

  const partialEvents = [], partial = new QuoteState('prices', (kind, row) => partialEvents.push({kind, ...row}));
  partial.accept(payload, 1);
  partial.accept({...payload, timestamp: '2026-10-29T00:00:00.123456787Z'}, 2);
  partial.accept(older, 3);
  equal(partial.regressions, 2);
  equal(partial.stateRollbacks, 1);
  equal(partialEvents[1].state_rolled_back, false);
  equal(partialEvents[1].previous.source_timestamp, '2026-10-29T00:00:00.123456787Z');

  const boundedEvents = [], bounded = new QuoteState('prices', (kind, row) => boundedEvents.push({kind, ...row}));
  bounded.accept(payload, 1);
  for (let i = 0; i < MAX_VIOLATION_DETAILS + 5; i++) bounded.accept(older, 2 + i);
  bounded.snapshot([payload.code], 100);
  equal(boundedEvents.filter(x => x.kind === 'quote_regression').length, MAX_VIOLATION_DETAILS);
  equal(bounded.regressions, MAX_VIOLATION_DETAILS + 5);
  equal(bounded.stateRollbacks, 1);
  equal(boundedEvents[boundedEvents.length - 1].violation_details_suppressed, 5);

  const sequenced = fixtures[1].payload, sequenceEvents = [];
  const sequenceTracker = new QuoteState('prices', (kind, row) => sequenceEvents.push({kind, ...row}));
  sequenceTracker.accept(sequenced, 1);
  sequenceTracker.accept({...sequenced, sequence: sequenced.sequence - 1,
    timestamp: '2026-10-30T00:00:00Z'}, 2);
  equal(sequenceEvents[0].comparison_field, 'sequence');
  equal(sequenceEvents[0].state_rolled_back, true);
  equal(sequenceEvents[0].received.sequence, sequenced.sequence - 1);

  const book = fixtures[2].payload, bookEvents = [];
  const bookTracker = new QuoteState('orderbooks', (kind, row) => bookEvents.push({kind, ...row}));
  bookTracker.accept(book, 1, {...context, event_name: 'orderbook'});
  const olderBook = {...book, timestamp: '2026-10-29T00:00:00.123455Z'};
  bookTracker.accept(olderBook, 2, {...context, code_payload_index: 2, event_name: 'orderbook'});
  equal(bookEvents[0].kind, 'quote_regression');
  equal(bookEvents[0].previous.hash, fingerprint('orderbooks', book).hash);
  equal(bookEvents[0].received.hash, fingerprint('orderbooks', olderBook).hash);
  equal(bookEvents[0].received.event_name, 'orderbook');
  equal(bookEvents[0].state_rolled_back, true);

  const cleanEvents = [], clean = new QuoteState('prices', (kind, row) => cleanEvents.push(row));
  clean.accept(payload, 1);
  clean.accept(payload, 2);
  clean.accept({...payload, code: 'Q00002', timestamp: '2026-10-28T00:00:00Z'}, 3);
  equal(cleanEvents.length, 0);
  equal(clean.regressions, 0);
}
