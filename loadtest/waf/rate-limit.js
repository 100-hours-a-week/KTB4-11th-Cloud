import http from 'k6/http';
import { check, sleep } from 'k6';
import { Counter, Rate, Trend } from 'k6/metrics';

// Run normal and flood modes on DIFFERENT source IPs to test normal-user protection.
// VUs on one generator share its egress IP; no X-Forwarded-For spoofing is used.
const base = (__ENV.BASE_URL || '').replace(/\/$/, '');
const mode = __ENV.MODE || 'normal';
const users = Number(__ENV.NORMAL_USERS || 1);
const cookie = __ENV.ACCESS_TOKEN ? `access_token=${__ENV.ACCESS_TOKEN}` : '';
const paths = JSON.parse(__ENV.NORMAL_PATHS || '["/api/v1/users/me"]');
if (!/^https?:\/\//.test(base)) throw new Error('Set BASE_URL explicitly.');
if (!['normal', 'flood'].includes(mode)) throw new Error('MODE must be normal or flood.');
if (![1, 10].includes(users)) throw new Error('NORMAL_USERS must be 1 or 10.');
if (!cookie) throw new Error('Set ACCESS_TOKEN to a valid test-account access token.');
if (!Array.isArray(paths) || paths.length === 0 || paths.some(p => typeof p !== 'string' || !p.startsWith('/api/'))) {
  throw new Error('NORMAL_PATHS must be a JSON array of /api/ paths for read-only GET requests.');
}
const floodPath = __ENV.FLOOD_PATH || '/api/v1/users/me';
if (!floodPath.startsWith('/api/')) throw new Error('FLOOD_PATH must start with /api/.');
const floodRps = Number(__ENV.FLOOD_RPS || 20);
if (!Number.isInteger(floodRps) || floodRps < 1) throw new Error('FLOOD_RPS must be a positive integer.');

const blocked = new Counter('waf_429_responses');
const normalErrors = new Rate('normal_request_errors');
const normalLatency = new Trend('normal_request_duration', true);
// Observation only: WAF logs provide the authoritative source-IP and detection timeline.
const floodBlocked = new Rate('flood_blocked_ratio');

export const options = {
  scenarios: mode === 'normal' ? {
    normal: { executor: 'per-vu-iterations', vus: users, iterations: 2, maxDuration: '5m30s', exec: 'normalVisit' },
  } : {
    flood: { executor: 'constant-arrival-rate', rate: floodRps, timeUnit: '1s', duration: '6m', preAllocatedVUs: 20, maxVUs: 100, exec: 'flood' },
  },
  thresholds: mode === 'normal' ? {
    normal_request_errors: ['rate==0'],
    normal_request_duration: [`p(95)<${Number(__ENV.NORMAL_P95_MS || 1000)}`],
  } : {},
  // Do not fail every flood request just because WAF intentionally returns 429.
};

function request(path, scenario) {
  const r = http.get(`${base}${path}`, {
    headers: { Cookie: cookie }, redirects: 0, timeout: '30s',
    tags: { scenario_type: scenario, name: path.split('?')[0] },
  });
  if (r.status === 429) blocked.add(1);
  return r;
}

export function normalVisit() {
  // Seven GETs per visit approximates the assumed 6.8 calls; two visits / five minutes.
  // With the default path this checks the limiter only. Supply real GET paths to model a user journey.
  for (let i = 0; i < 7; i++) {
    const r = request(paths[i % paths.length], 'normal');
    normalErrors.add(r.status < 200 || r.status >= 300);
    normalLatency.add(r.timings.duration);
    check(r, { 'normal request succeeds': response => response.status >= 200 && response.status < 300 });
    sleep(0.2);
  }
  sleep(148.6);
}

export function flood() {
  const r = request(floodPath, 'flood');
  floodBlocked.add(r.status === 429);
}
