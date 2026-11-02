import {QuoteState} from './quote_state.js';
import sse from 'k6/x/sse';
import http from 'k6/http';
import exec from 'k6/execution';
import {sleep} from 'k6';
import {Counter, Trend} from 'k6/metrics';

const plan = JSON.parse(open(__ENV.FIS_PLAN));
const scenarios = {};
for (const [group, config] of Object.entries(plan.groups)) {
  scenarios[group] = {
    executor: 'ramping-vus', startVUs: 0, gracefulRampDown: '0s', gracefulStop: '0s',
    stages: [{duration: `${plan.ramp_seconds}s`, target: config.connections},
      // The supervisor ends measurement before interrupting clients. Reserve time
      // so the executor does not create its own teardown events at our boundary.
      {duration: `${plan.budget_seconds - plan.ramp_seconds + 30}s`, target: config.connections}],
    tags: {group, stream: config.stream},
  };
}
export const options = {
  scenarios, maxRedirects: 0,
  summaryTrendStats: ['avg', 'min', 'med', 'p(95)', 'p(99)', 'max'],
  tags: {test_id: plan.test_id || 'inspect', service: 'market-http', experiment: plan.experiment || 'T1'},
  // No latency/error abort thresholds: expected disconnections must be measured.
};

const errors = new Counter('fis_transport_errors');
const reconnectMs = new Trend('fis_reconnect_ms', true);
const updateMs = new Trend('fis_first_advancing_data_ms', true);
const sourceAge = new Trend('fis_source_age_ms', true);
const freshMs = new Trend('fis_fresh_data_recovery_ms', true);
let attempt = 0;
let restReady = false;
let everConnected = false;
let lastUpdate = null;
let lastFrame = null;
let lastTick = 0;
let updates = 0;
let frames = 0;
let outage = null;
let outageNumber = 0;
let samples = 0;
let quoteState = null;
const sources = {};

function emit(kind, fields = {}) {
  console.log('FIS_EVENT ' + JSON.stringify({kind, at_ms: Date.now(),
    client_id: String(exec.vu.idInTest), group: exec.scenario.name,
    stream: plan.groups[exec.scenario.name].stream, attempt, ...fields}));
}

function valid(payload, stream, codes) {
  if (!payload || !codes.includes(payload.code) || !Number.isFinite(Date.parse(payload.timestamp))) return false;
  if (stream === 'prices') return Number.isFinite(payload.price) && payload.price >= 0;
  const level = x => x && Number.isFinite(x.price) && x.price >= 0 && Number.isFinite(x.qty) && x.qty >= 0;
  return Array.isArray(payload.asks) && Array.isArray(payload.bids) &&
    payload.asks.length === 10 && payload.bids.length === 10 && payload.asks.every(level) && payload.bids.every(level);
}

function retry() {
  sleep((plan.retry_min_ms + Math.random() * (plan.retry_max_ms - plan.retry_min_ms)) / 1000);
}

export default function () {
  attempt += 1;
  const group = exec.scenario.name;
  const cfg = plan.groups[group];
  if (plan.quote_state_enabled && !quoteState) quoteState = new QuoteState(cfg.stream, emit);
  const available = plan.codes[cfg.stream];
  const offset = (exec.vu.idInTest * 7 + Object.keys(plan.groups).indexOf(group) * 31) % available.length;
  const codes = Array.from({length: cfg.code_count}, (_, i) => available[(offset + i) % available.length]);
  const query = encodeURIComponent(codes.join(','));
  if (!restReady) {
    try {
      const response = http.get(`${plan.base_url}/${cfg.stream}?codes=${query}`,
        {timeout: '10s', redirects: 0, tags: {name: `initial-${cfg.stream}`}});
      const body = response.status === 200 ? response.json() : null;
      restReady = Array.isArray(body) && body.every(p => valid(p, cfg.stream, codes));
      if (restReady && body.length === 0) emit('initial_rest_empty', {status: response.status});
      if (!restReady) emit('initial_rest_error', {status: response.status});
    } catch (_) { emit('initial_rest_error', {status: null}); }
    if (!restReady) { retry(); return; }
  }
  const sessionStarted = Date.now();
  let headersAt = null;
  let connectedAt = null;
  let sessionPayloads = 0;
  const codePayloads = {};
  let connected = false;
  let errorReported = false;
  const seen = new Set();
  const advanced = new Set();
  emit('attempt');
  if (quoteState) emit('quote_subscription', {codes});
  function transportError(detail) {
    if (!errorReported) {
      errors.add(1);
      emit('transport_error', {detail: String(detail || 'stream ended').slice(0, 240)});
      errorReported = true;
    }
  }
  try {
    const response = sse.open(`${plan.base_url}/${cfg.stream}/stream?codes=${query}`,
      {method: 'GET', timeout: `${plan.budget_seconds + 30}s`,
        headers: {Accept: 'text/event-stream', 'Cache-Control': 'no-cache'}, tags: {name: `sse-${cfg.stream}`}}, client => {
        client.on('open', () => { headersAt = Date.now(); emit('headers'); });
        client.on('event', event => {
          const now = Date.now();
          let payload = null;
          if (event.data) {
            try {payload = JSON.parse(event.data);} catch (_) { /* rejected below */ }
            if (String(event.name || '').trim() !== (cfg.stream === 'prices' ? 'price' : 'orderbook') ||
                !valid(payload, cfg.stream, codes)) {
              emit('bad_payload', {event_name: String(event.name || '')});
              client.close();
              return;
            }
          } else if (!event.comment) { return; }
          lastFrame = now;
          frames += 1;
          if (!connected) {
            connected = true;
            connectedAt = now;
            everConnected = true;
            emit('connected', {post_initial_updates: updates, last_update_ms: lastUpdate});
            if (outage && !outage.connected) {
              outage.connected = now;
              reconnectMs.add(now - outage.at);
              emit('reconnected', {outage_id: outage.id});
            }
          }
          if (payload && quoteState && outage && !outage.firstPayload) {
            outage.firstPayload = now;
            emit('recovery_first_payload', {outage_id: outage.id, elapsed_ms: now - outage.at});
          }
          if (payload && quoteState) {
            sessionPayloads++;
            codePayloads[payload.code] = (codePayloads[payload.code] || 0) + 1;
            try { quoteState.accept(payload, now, {
              attempt, session_started_ms: sessionStarted, session_headers_ms: headersAt,
              session_connected_ms: connectedAt, session_payload_index: sessionPayloads,
              code_payload_index: codePayloads[payload.code], event_name: String(event.name || ''),
              event_id: event.id == null ? undefined : String(event.id).slice(0, 128),
            }); }
            catch (error) { emit('quote_measurement_error', {detail: String(error)}); client.close(); return; }
          }
          if (payload) {
            const stamp = Date.parse(payload.timestamp);
            const prior = sources[payload.code];
            const incremental = seen.has(payload.code);
            seen.add(payload.code);
            sources[payload.code] = Math.max(prior || 0, stamp);
            if (incremental && prior !== undefined && stamp > prior) {
              advanced.add(payload.code);
              updates += 1;
              lastUpdate = now;
              if (++samples % plan.source_age_sample_every === 0) sourceAge.add(now - stamp);
              if (outage && !outage.updated) {
                outage.updated = now;
                updateMs.add(now - outage.at);
                emit('recovery_update', {outage_id: outage.id, source_age_ms: now - stamp,
                  source_timestamp_ms: stamp, code: payload.code, last_update_ms: outage.lastUpdate});
              }
            }
          }
          // Every subscribed code must advance in this session. Neither the
          // reconnect snapshot nor a replayed backlog qualifies as fresh data.
          const oldest = advanced.size === codes.length ? Math.min(...codes.map(code => sources[code])) : null;
          const newest = advanced.size === codes.length ? Math.max(...codes.map(code => sources[code])) : null;
          if (outage && oldest !== null && oldest >= outage.at &&
              now - oldest <= plan.max_source_age_ms && newest - now <= plan.max_future_skew_ms) {
            freshMs.add(now - outage.at);
            emit('fresh_recovery', {outage_id: outage.id, max_source_age_ms: now - oldest,
              oldest_source_timestamp_ms: oldest, code_count: codes.length});
            outage = null;
          }
          if (!lastTick || now - lastTick >= plan.snapshot_interval_ms) {
            if (quoteState) quoteState.snapshot(codes, now);
            emit('snapshot', {last_frame_ms: lastFrame, last_update_ms: lastUpdate,
              post_initial_updates: updates, frames,
              oldest_advancing_source_ms: oldest, newest_advancing_source_ms: newest});
            lastTick = now;
          }
        });
        client.on('error', error => { transportError(error); client.close(); });
      });
    if (!response || response.status !== 200 || response.error) transportError(response && response.error);
  } catch (error) { transportError(error); }
  if (quoteState) quoteState.snapshot(codes, Date.now());
  if (connected || everConnected) {
    if (!outage) {
      outage = {id: ++outageNumber, at: Date.now(), lastUpdate};
      emit('disconnected', {outage_id: outage.id, last_update_ms: lastUpdate});
    } else {
      // A reconnect that ends before a new update is still the same unresolved outage.
      emit('session_ended', {outage_id: outage.id});
    }
  }
  retry();
}

export function handleSummary(data) {
  return __ENV.FIS_SUMMARY ? {[__ENV.FIS_SUMMARY]: JSON.stringify(data, null, 2)} : {};
}
