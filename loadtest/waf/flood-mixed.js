import http from 'k6/http';
import { check, sleep } from 'k6';
import { Counter, Rate, Trend } from 'k6/metrics';

// One k6 process represents one traffic source. Use a separate process and a
// distinct WAF-visible egress IP for the normal cohort and each attack profile.
const base = (__ENV.BASE_URL || '').replace(/\/$/, '');
const role = __ENV.ROLE || '';
const attackProfile = __ENV.ATTACK_PROFILE || '';
const tokenFile = __ENV.ACCESS_TOKEN_FILE || '';
const normalUsers = Number(__ENV.NORMAL_USERS || 10);
const normalThinkTimeSeconds = Number(__ENV.NORMAL_THINK_TIME_SECONDS || 148.6);
const normalThinkJitterSeconds = Number(__ENV.NORMAL_THINK_JITTER_SECONDS || 10);
const normalInitialJitterSeconds = Number(__ENV.NORMAL_INITIAL_JITTER_SECONDS || 20);
const floodRps = Number(__ENV.FLOOD_RPS || 3);
const journeyFloodsPerMinute = Number(__ENV.JOURNEY_FLOODS_PER_MINUTE || 24);
const burstPeakRps = Number(__ENV.BURST_PEAK_RPS || 5);
const normalP95Ms = Number(__ENV.NORMAL_P95_MS || 1000);
const suppliedAccountId = __ENV.NORMAL_ACCOUNT_ID || '';

const defaultNormalPaths = [
  '/api/v1/users/me',
  '/api/v1/users/me/accounts/{accountId}',
  '/api/v1/users/me/accounts/{accountId}/holdings?sort=latest_purchase&order=desc&limit=3',
  '/api/v1/accounts/{accountId}/orders?limit=3&order_status=executed',
  '/api/v1/users/me/accounts',
  '/api/v2/users/me/watchlist',
  '/api/v1/users/me/accounts',
];

let normalPaths = defaultNormalPaths;
if (__ENV.NORMAL_PATHS) {
  try {
    normalPaths = JSON.parse(__ENV.NORMAL_PATHS);
  } catch (error) {
    throw new Error(`NORMAL_PATHS must be valid JSON: ${error.message}`);
  }
}

if (!/^https:\/\//.test(base)) throw new Error('Set BASE_URL to an explicit HTTPS URL.');
if (!['normal', 'attack'].includes(role)) throw new Error('ROLE must be normal or attack.');
if (!tokenFile) throw new Error('Set ACCESS_TOKEN_FILE to a short-lived test JWT file.');
if (!Array.isArray(normalPaths) || normalPaths.length === 0
    || normalPaths.some(path => typeof path !== 'string' || !path.startsWith('/api/'))) {
  throw new Error('NORMAL_PATHS must be a non-empty JSON array of /api/ GET paths.');
}
if (!Number.isInteger(normalUsers) || normalUsers < 1 || normalUsers > 10) {
  throw new Error('NORMAL_USERS must be an integer from 1 through 10.');
}
if (!Number.isFinite(normalThinkTimeSeconds)
    || normalThinkTimeSeconds < 30 || normalThinkTimeSeconds > 300) {
  throw new Error('NORMAL_THINK_TIME_SECONDS must be between 30 and 300.');
}
if (!Number.isFinite(normalThinkJitterSeconds)
    || normalThinkJitterSeconds < 0 || normalThinkJitterSeconds > 30) {
  throw new Error('NORMAL_THINK_JITTER_SECONDS must be between 0 and 30.');
}
if (!Number.isFinite(normalInitialJitterSeconds)
    || normalInitialJitterSeconds < 0 || normalInitialJitterSeconds > 60) {
  throw new Error('NORMAL_INITIAL_JITTER_SECONDS must be between 0 and 60.');
}
if (suppliedAccountId && !/^[1-9]\d*$/.test(suppliedAccountId)) {
  throw new Error('NORMAL_ACCOUNT_ID must be a positive integer.');
}

const floodPath = __ENV.FLOOD_PATH || '/api/v1/users/me';
if (!floodPath.startsWith('/api/')) throw new Error('FLOOD_PATH must start with /api/.');

if (role === 'attack') {
  if (!['capec_get', 'journey_flood', 'burst_flood'].includes(attackProfile)) {
    throw new Error('ATTACK_PROFILE must be capec_get, journey_flood, or burst_flood.');
  }
  if (__ENV.WAF_MODE_CONFIRMED !== 'block') {
    throw new Error('Confirm the deployed Web ACL is in BLOCK mode and set WAF_MODE_CONFIRMED=block.');
  }
  if (!Number.isInteger(floodRps) || floodRps < 1 || floodRps > 5) {
    throw new Error('FLOOD_RPS must be an integer from 1 through 5.');
  }
  if (!Number.isInteger(journeyFloodsPerMinute)
      || journeyFloodsPerMinute < 1 || journeyFloodsPerMinute > 30) {
    throw new Error('JOURNEY_FLOODS_PER_MINUTE must be an integer from 1 through 30.');
  }
  if (!Number.isInteger(burstPeakRps) || burstPeakRps < 2 || burstPeakRps > 5) {
    throw new Error('BURST_PEAK_RPS must be an integer from 2 through 5.');
  }
}

let tokenRecords;
try {
  tokenRecords = JSON.parse(open(tokenFile));
} catch (error) {
  throw new Error(`ACCESS_TOKEN_FILE must contain valid JSON: ${error.message}`);
}
if (!Array.isArray(tokenRecords) || tokenRecords.length !== 1
    || typeof tokenRecords[0].access_token !== 'string' || !tokenRecords[0].access_token) {
  throw new Error('ACCESS_TOKEN_FILE must contain exactly one record with an access_token.');
}
const accessToken = tokenRecords[0].access_token;

const normalUnexpected = new Rate('normal_unexpected_response_ratio');
const normal2xx = new Counter('normal_2xx_responses');
const normal429 = new Counter('normal_429_responses');
const normalOther = new Counter('normal_other_responses');
const normalLatency = new Trend('normal_request_duration', true);
const attackUnexpected = new Rate('attack_unexpected_response_ratio');
const attackBlockedRatio = new Rate('attack_429_ratio');
const attack2xx = new Counter('attack_2xx_responses');
const attack429 = new Counter('attack_429_responses');
const attackOther = new Counter('attack_other_responses');
const attackLatency = new Trend('attack_request_duration', true);
const first429ByVu = {};

const normalScenario = {
  normal: {
    executor: 'constant-vus',
    vus: normalUsers,
    duration: '7m30s',
    exec: 'normalUserLoop',
  },
};

let attackScenario;
if (attackProfile === 'capec_get') {
  attackScenario = {
    capec_get: {
      executor: 'constant-arrival-rate',
      rate: floodRps,
      timeUnit: '1s',
      duration: '6m',
      preAllocatedVUs: 10,
      maxVUs: 20,
      exec: 'attack',
    },
  };
} else if (attackProfile === 'journey_flood') {
  attackScenario = {
    journey_flood: {
      executor: 'constant-arrival-rate',
      rate: journeyFloodsPerMinute,
      timeUnit: '1m',
      duration: '6m',
      preAllocatedVUs: 10,
      maxVUs: 20,
      exec: 'attack',
    },
  };
} else if (attackProfile === 'burst_flood') {
  attackScenario = {
    burst_flood: {
      executor: 'ramping-arrival-rate',
      startRate: 1,
      timeUnit: '1s',
      stages: [
        { target: 1, duration: '10s' },
        { target: burstPeakRps, duration: '10s' },
        { target: burstPeakRps, duration: '150s' },
        { target: 1, duration: '10s' },
      ],
      preAllocatedVUs: 10,
      maxVUs: 20,
      exec: 'attack',
    },
  };
}

export const options = {
  scenarios: role === 'normal' ? normalScenario : attackScenario,
  thresholds: role === 'normal' ? {
    normal_unexpected_response_ratio: ['rate==0'],
    normal_request_duration: [`p(95)<${normalP95Ms}`],
  } : {
    attack_unexpected_response_ratio: ['rate==0'],
    attack_429_ratio: ['rate>0'],
  },
};

function pathForVisit(path, accountId) {
  return path.replace(/\{accountId\}/g, accountId || '');
}

export function setup() {
  let accountId = suppliedAccountId;
  const requiresAccountId = ((role === 'normal' || attackProfile === 'journey_flood')
    && normalPaths.some(path => path.includes('{accountId}')))
    || floodPath.includes('{accountId}');

  if (requiresAccountId && !accountId) {
    const response = http.get(`${base}/api/v1/users/me/accounts`, {
      headers: { Cookie: `access_token=${accessToken}` },
      redirects: 0,
      timeout: '30s',
      tags: { scenario_type: 'auth_setup', name: 'test_user_accounts' },
    });
    if (response.status !== 200) {
      throw new Error(`Could not load accounts for the test user (HTTP ${response.status}).`);
    }
    const accounts = response.json();
    if (!Array.isArray(accounts) || accounts.length === 0
        || !/^[1-9]\d*$/.test(String(accounts[0].account_id))) {
      throw new Error('The selected test user has no account; use an onboarded fixture user.');
    }
    accountId = String(accounts[0].account_id);
  }
  return { accountId };
}

function request(path, data, trafficRole) {
  const response = http.get(`${base}${path}`, {
    headers: { Cookie: `access_token=${accessToken}` },
    redirects: 0,
    timeout: '30s',
    responseType: 'binary',
    tags: {
      scenario_type: trafficRole,
      attack_profile: trafficRole === 'attack' ? attackProfile : 'normal',
      name: path.split('?')[0],
    },
  });

  const ok = response.status >= 200 && response.status < 300;
  const wafBlocked = response.status === 429;
  const uri = path.split('?')[0].replace(/\/\d+(?=\/|$)/g, '/{id}');
  const metricTags = {
    scenario_type: trafficRole,
    attack_profile: trafficRole === 'attack' ? attackProfile : 'normal',
    uri,
  };

  if (trafficRole === 'normal') {
    normalUnexpected.add(!ok, metricTags);
    normalLatency.add(response.timings.duration, metricTags);
    if (ok) normal2xx.add(1, metricTags);
    else if (wafBlocked) normal429.add(1, metricTags);
    else normalOther.add(1, metricTags);
    check(response, { 'normal API request returns 2xx': () => ok });
  } else {
    const expected = ok || wafBlocked;
    attackUnexpected.add(!expected, metricTags);
    attackBlockedRatio.add(wafBlocked, metricTags);
    attackLatency.add(response.timings.duration, metricTags);
    if (ok) attack2xx.add(1, metricTags);
    else if (wafBlocked) attack429.add(1, metricTags);
    else attackOther.add(1, metricTags);
    check(response, { 'attack request returns 2xx or 429': () => expected });

    if (wafBlocked && !first429ByVu[__VU]) {
      first429ByVu[__VU] = true;
      console.log(`K6_EVENT ${JSON.stringify({
        kind: 'first_http_429_by_vu',
        role: trafficRole,
        attack_profile: attackProfile,
        at_utc: new Date().toISOString(),
        vu: __VU,
        uri,
      })}`);
    }
  }

  return response;
}

function visitNormalPaths(data) {
  for (const path of normalPaths) {
    request(pathForVisit(path, data.accountId), data, 'normal');
    sleep(0.2);
  }
}

export function normalUserLoop(data) {
  if (__ITER === 0 && normalInitialJitterSeconds > 0) {
    sleep(Math.random() * normalInitialJitterSeconds);
  }
  visitNormalPaths(data);
  sleep(normalThinkTimeSeconds + Math.random() * normalThinkJitterSeconds);
}

export function attack(data) {
  if (attackProfile === 'journey_flood') {
    for (const path of normalPaths) {
      request(pathForVisit(path, data.accountId), data, 'attack');
      sleep(0.2);
    }
    return;
  }
  request(pathForVisit(floodPath, data.accountId), data, 'attack');
}
