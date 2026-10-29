import {fingerprint, QuoteState} from './quote_state.js';
const fixtures = JSON.parse(open('./quote-fixtures.json'));
export const options = {vus: 1, iterations: 1};
function equal(a, b) {if (JSON.stringify(a) !== JSON.stringify(b)) throw new Error(JSON.stringify({a, b}));}
export default function() {
  for (const f of fixtures) equal(fingerprint(f.stream, f.payload), f.expected);
  const events = [], tracker = new QuoteState('prices', (kind, row) => events.push(row));
  const payload = fixtures[0].payload;
  tracker.accept(payload, 10);
  tracker.accept({...payload, price: 101}, 20);
  tracker.accept({...payload, timestamp: '2026-10-29T00:00:00.123456788Z'}, 30);
  tracker.snapshot([payload.code], 40);
  equal(events[0].regressions, 1);
  equal(events[0].conflicts, 1);
  equal(events[0].states[payload.code].since_ms, 30);
  tracker.accept(payload, 50);
  tracker.accept(payload, 60);
  equal(tracker.latest[payload.code].since_ms, 50);
}
