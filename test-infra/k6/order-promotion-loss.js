import http from 'k6/http';
import { check, fail } from 'k6';
import { Counter, Rate, Trend } from 'k6/metrics';

const baseUrl = (__ENV.K6_BASE_URL || '').replace(/\/$/, '');
const accessToken = __ENV.K6_ACCESS_TOKEN || '';
const runId = __ENV.K6_RUN_ID || '';
const accountIds = (__ENV.K6_ACCOUNT_IDS || '')
  .split(',')
  .map((value) => value.trim())
  .filter(Boolean);
const stockCode = __ENV.K6_STOCK_CODE || '005930';
const stockName = __ENV.K6_STOCK_NAME || '삼성전자';
const limitPrice = Number(__ENV.K6_LIMIT_PRICE || '1');
const rate = Number(__ENV.K6_RATE || '1');
const duration = __ENV.K6_DURATION || '10m';
const preAllocatedVUs = Number(__ENV.K6_PRE_ALLOCATED_VUS || '2');
const maxVUs = Number(__ENV.K6_MAX_VUS || '10');

function requireValue(value, name) {
  if (!value) throw new Error(`${name} is required`);
}

function requirePositiveInteger(value, name) {
  if (!Number.isInteger(value) || value <= 0) {
    throw new Error(`${name} must be a positive integer`);
  }
}

requireValue(baseUrl, 'K6_BASE_URL');
requireValue(accessToken, 'K6_ACCESS_TOKEN');
requireValue(runId, 'K6_RUN_ID');
requireValue(accountIds.length > 0, 'K6_ACCOUNT_IDS');
if (!/^[A-Za-z0-9-]{1,40}$/.test(runId)) {
  throw new Error('K6_RUN_ID may contain only letters, numbers, and hyphens (1-40 chars)');
}
if (!/^[0-9]{6}$/.test(stockCode)) throw new Error('K6_STOCK_CODE must be six digits');
if (!accountIds.every((value) => /^[0-9]+$/.test(value))) {
  throw new Error('K6_ACCOUNT_IDS must be comma-separated numeric account IDs');
}
requirePositiveInteger(limitPrice, 'K6_LIMIT_PRICE');
requirePositiveInteger(rate, 'K6_RATE');
requirePositiveInteger(preAllocatedVUs, 'K6_PRE_ALLOCATED_VUS');
requirePositiveInteger(maxVUs, 'K6_MAX_VUS');
if (maxVUs < preAllocatedVUs) throw new Error('K6_MAX_VUS must be >= K6_PRE_ALLOCATED_VUS');
if (__ENV.K6_CONFIRM_ORDER_WRITES !== 'YES') {
  throw new Error('Set K6_CONFIRM_ORDER_WRITES=YES to enable persistent order creation');
}

const orderAttempts = new Counter('order_attempts');
const orderAccepted = new Counter('order_accepted');
const orderRejected = new Counter('order_rejected_4xx');
const orderAmbiguous = new Counter('order_ambiguous_outcome');
const orderUnexpected = new Counter('order_unexpected_response');
const orderAcceptedRate = new Rate('order_accepted_rate');
const orderPendingRate = new Rate('order_pending_rate');
const orderApiLatency = new Trend('order_api_latency', true);

export const options = {
  scenarios: {
    order_write_during_promotion: {
      executor: 'constant-arrival-rate',
      rate,
      timeUnit: '1s',
      duration,
      preAllocatedVUs,
      maxVUs,
      exec: 'createLimitOrder',
    },
  },
};

let csrfToken = '';

function getCsrfToken() {
  if (csrfToken) return csrfToken;

  // Each VU has its own cookie jar. The response sets XSRF-TOKEN; the access token
  // is supplied as the same cookie used by the backend's normal API clients.
  const jar = http.cookieJar();
  jar.set(baseUrl, 'access_token', accessToken);
  const response = http.get(`${baseUrl}/api/v1/auth/csrf`, {
    headers: { Accept: 'application/json' },
    tags: { endpoint: 'csrf' },
  });
  let body;
  try {
    body = response.json();
  } catch (_) {
    body = null;
  }
  if (response.status !== 200 || !body || !body.token) {
    console.error(`K6_CSRF_ERROR ${JSON.stringify({ status: response.status })}`);
    fail('Could not obtain CSRF token; no order request was sent by this VU');
  }
  csrfToken = body.token;
  return csrfToken;
}

function responseBody(response) {
  try {
    return response.json();
  } catch (_) {
    return null;
  }
}

export function createLimitOrder() {
  const accountId = accountIds[(__VU - 1) % accountIds.length];
  const marker = `k6-migration-${runId}:account=${accountId}:vu=${__VU}:iter=${__ITER}`;
  const startedAt = new Date().toISOString();
  const token = getCsrfToken();

  orderAttempts.add(1, { run_id: runId });
  // Log intent before the network call so an interrupted request still has a
  // marker that can be searched for on the old and promoted databases.
  console.log(`ORDER_ATTEMPT ${JSON.stringify({ marker, account_id: accountId, started_at: startedAt })}`);

  const payload = {
    stock_code: stockCode,
    stock_name: stockName,
    order_side: 'buy',
    order_type: 'limit',
    limit_price: limitPrice,
    quantity: 1,
    holding_weight_limit_percent: 100,
    is_lower_triggered: false,
    reason: marker,
  };

  const response = http.post(
    `${baseUrl}/api/v1/accounts/${accountId}/orders`,
    JSON.stringify(payload),
    {
      headers: {
        Accept: 'application/json',
        'Content-Type': 'application/json',
        'X-XSRF-TOKEN': token,
      },
      timeout: __ENV.K6_REQUEST_TIMEOUT || '30s',
      tags: { endpoint: 'orders.create', run_id: runId },
    },
  );

  const body = responseBody(response);
  const hasOrderId = body && body.order_id !== null && body.order_id !== undefined
    && Number.isFinite(Number(body.order_id)) && Number(body.order_id) > 0;
  const accepted = response.status === 201 && hasOrderId;
  const pending = accepted && body.order_status === 'pending';
  orderApiLatency.add(response.timings.duration, { run_id: runId });
  orderAcceptedRate.add(accepted, { run_id: runId });
  orderPendingRate.add(pending, { run_id: runId });

  if (accepted) {
    orderAccepted.add(1, { run_id: runId });
  } else if (response.status >= 400 && response.status < 500) {
    orderRejected.add(1, { run_id: runId, status: String(response.status) });
  } else if (response.status === 0 || response.status >= 500) {
    // A timeout or 5xx can happen after the database committed. The marker query
    // in the README determines whether this particular request was persisted.
    orderAmbiguous.add(1, { run_id: runId, status: String(response.status) });
  } else {
    orderUnexpected.add(1, { run_id: runId, status: String(response.status) });
  }

  check(response, {
    'order create returned HTTP 201 and order_id': () => accepted,
    'order remains pending': () => pending,
  });

  console.log(`ORDER_RESULT ${JSON.stringify({
    marker,
    finished_at: new Date().toISOString(),
    status: response.status,
    order_id: hasOrderId ? body.order_id : null,
    order_status: body && body.order_status ? body.order_status : null,
    latency_ms: response.timings.duration,
  })}`);
}
