import http from 'k6/http';
import { check, sleep } from 'k6';
import { Counter, Rate, Trend } from 'k6/metrics';

// Run normal and flood modes on DIFFERENT source IPs to test normal-user protection.
// VUs on one generator share its egress IP; no X-Forwarded-For spoofing is used.
const base = (__ENV.BASE_URL || '').replace(/\/$/, '');
const mode = __ENV.MODE || 'smoke';
const users = Number(__ENV.NORMAL_USERS || 10);
const cookie = __ENV.ACCESS_TOKEN ? `access_token=${__ENV.ACCESS_TOKEN}` : '';
// Candidate seven-GET journey from the current FE calls: identity, home data,
// account list, watchlist, then a repeated account view. This is a hypothesis,
// not a measured production request mix; NORMAL_PATHS can override it.
const defaultNormalPaths = [
  '/api/v1/users/me',
  '/api/v1/users/me/accounts/{accountId}',
  '/api/v1/users/me/accounts/{accountId}/holdings?sort=latest_purchase&order=desc&limit=3',
  '/api/v1/accounts/{accountId}/orders?limit=3&order_status=executed',
  '/api/v1/users/me/accounts',
  '/api/v2/users/me/watchlist',
  '/api/v1/users/me/accounts',
];
const rawPaths = JSON.parse(__ENV.NORMAL_PATHS || JSON.stringify(defaultNormalPaths));
const normalAccountId = __ENV.NORMAL_ACCOUNT_ID || '';
if (!/^https?:\/\//.test(base)) throw new Error('Set BASE_URL explicitly.');
if (!['smoke', 'normal', 'flood'].includes(mode)) throw new Error('MODE must be smoke, normal, or flood.');
if (![1, 10].includes(users)) throw new Error('NORMAL_USERS must be 1 or 10.');
if (!cookie) throw new Error('Set ACCESS_TOKEN to a valid test-account access token.');
if (!Array.isArray(rawPaths) || rawPaths.length === 0 || rawPaths.some(p => typeof p !== 'string' || !p.startsWith('/api/'))) {
  throw new Error('NORMAL_PATHS must be a JSON array of /api/ paths for read-only GET requests.');
}
if (mode !== 'flood' && rawPaths.some(path => path.includes('{accountId}')) && !/^[1-9]\d*$/.test(normalAccountId)) {
  throw new Error('Set NORMAL_ACCOUNT_ID to a disposable test account ID for the default user journey.');
}
const paths = rawPaths.map(path => path.replace(/\{accountId\}/g, normalAccountId));
const floodPath = __ENV.FLOOD_PATH || '/api/v1/users/me';
if (!floodPath.startsWith('/api/')) throw new Error('FLOOD_PATH must start with /api/.');
// With the repository default WAF limit (500 / 300s), 3 RPS produces 900
// requests in a full five-minute window. Keep this configurable for overrides.
const floodRps = Number(__ENV.FLOOD_RPS || 3);
if (!Number.isInteger(floodRps) || floodRps < 1) throw new Error('FLOOD_RPS must be a positive integer.');

const blocked = new Counter('waf_429_responses');
const normalErrors = new Rate('normal_request_errors');
const normalLatency = new Trend('normal_request_duration', true);
// Separate expected WAF throttling (429) from application/network failures.
const floodBlocked = new Rate('flood_blocked_ratio');
const flood2xx = new Counter('flood_2xx_responses');
const flood429 = new Counter('flood_429_responses');
const floodOther = new Counter('flood_other_responses');
const floodUnexpected = new Rate('flood_unexpected_response_ratio');
const floodLatency = new Trend('flood_request_duration', true);
const responseBodyBytes = new Trend('response_body_bytes');
const responseContentLengthBytes = new Trend('response_content_length_bytes');
const first429LoggedByScenario = {};

export const options = {
  scenarios: mode === 'smoke' ? {
    smoke: { executor: 'shared-iterations', vus: 1, iterations: 1, maxDuration: '1m', exec: 'normalVisit' },
  } : mode === 'normal' ? {
    normal: { executor: 'per-vu-iterations', vus: users, iterations: 2, maxDuration: '5m30s', exec: 'normalVisit' },
  } : {
    flood: { executor: 'constant-arrival-rate', rate: floodRps, timeUnit: '1s', duration: '6m', preAllocatedVUs: 10, maxVUs: 20, exec: 'flood' },
  },
  thresholds: mode !== 'flood' ? {
    normal_request_errors: ['rate==0'],
    normal_request_duration: [`p(95)<${Number(__ENV.NORMAL_P95_MS || 1000)}`],
  } : {},
  // Do not fail every flood request just because WAF intentionally returns 429.
};

function request(path, scenario) {
  const r = http.get(`${base}${path}`, {
    headers: { Cookie: cookie }, redirects: 0, timeout: '30s',
    responseType: 'binary',
    tags: { scenario_type: scenario, name: path.split('?')[0] },
  });
  const uri = path.split('?')[0].replace(/\/\d+(?=\/|$)/g, '/{id}');
  const metricTags = { scenario_type: scenario, uri };
  responseBodyBytes.add(r.body && typeof r.body.byteLength === 'number' ? r.body.byteLength : 0, metricTags);
  const contentLength = r.headers['Content-Length'];
  if (Array.isArray(contentLength) && contentLength.length > 0 && /^\d+$/.test(contentLength[0])) {
    responseContentLengthBytes.add(Number(contentLength[0]), metricTags);
  }
  if (r.status === 429 && !first429LoggedByScenario[scenario]) {
    first429LoggedByScenario[scenario] = true;
    console.log(`K6_EVENT ${JSON.stringify({
      kind: 'first_http_429_by_vu',
      scenario_type: scenario,
      at_utc: new Date().toISOString(),
      vu: __VU,
      uri,
    })}`);
  }
  if (r.status === 429) blocked.add(1);
  return r;
}

export function normalVisit() {
  // Seven read-only GETs per visit approximates the assumed 6.8 calls; two visits / five minutes.
  // Ten VUs share this generator's source IP, matching the WAF's IP aggregation key.
  for (let i = 0; i < 7; i++) {
    const r = request(paths[i % paths.length], 'normal');
    normalErrors.add(r.status < 200 || r.status >= 300);
    normalLatency.add(r.timings.duration);
    check(r, { 'normal request succeeds': response => response.status >= 200 && response.status < 300 });
    sleep(0.2);
  }
  if (mode === 'normal') sleep(148.6);
}

export function flood() {
  const r = request(floodPath, 'flood');
  floodBlocked.add(r.status === 429);
  floodLatency.add(r.timings.duration);

  if (r.status >= 200 && r.status < 300) {
    flood2xx.add(1);
    floodUnexpected.add(false);
  } else if (r.status === 429) {
    flood429.add(1);
    floodUnexpected.add(false);
  } else {
    // Includes other HTTP errors and status 0 for a transport failure.
    floodOther.add(1);
    floodUnexpected.add(true);
  }
}
