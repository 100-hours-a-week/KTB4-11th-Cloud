import http from "k6/http";
import { check } from "k6";
import { Counter, Trend } from "k6/metrics";

const apiBaseUrl = (__ENV.API_BASE_URL || "https://stock-spoon.com").replace(/\/+$/, "");
const tokenFile = __ENV.DB_FIS_PROBE_TOKEN_FILE;
const runId = __ENV.DB_FIS_RUN_ID || "unassigned";

if (!tokenFile) {
  throw new Error("Set DB_FIS_PROBE_TOKEN_FILE to a protected file containing one raw JWT.");
}

const token = open(tokenFile).trim();
if (!token) {
  throw new Error("DB_FIS_PROBE_TOKEN_FILE is empty.");
}

const probeSuccess = new Counter("db_path_probe_success_total");
const probeFailure = new Counter("db_path_probe_failure_total");
const probeLatency = new Trend("db_path_probe_duration_ms", true);

export const options = {
  scenarios: {
    db_path_probe: {
      executor: "constant-arrival-rate",
      rate: 1,
      timeUnit: "1s",
      duration: __ENV.DURATION || "20m",
      preAllocatedVUs: 4,
      maxVUs: 4,
    },
  },
  maxRedirects: 0,
  summaryTrendStats: ["avg", "min", "med", "p(95)", "p(99)", "max"],
};

export default function () {
  const startedAt = new Date().toISOString();
  const response = http.get(apiBaseUrl + "/api/v1/users/me/accounts", {
    headers: {
      Accept: "application/json",
      Authorization: "Bearer " + token,
    },
    timeout: "3s",
    tags: {
      name: "GET /api/v1/users/me/accounts",
      probe: "db-path-rto",
    },
  });

  let hasAccount = false;
  if (response.status === 200) {
    try {
      const accounts = response.json();
      hasAccount = Array.isArray(accounts) && accounts.length > 0;
    } catch (_) {
      hasAccount = false;
    }
  }

  const healthy = response.status === 200 && hasAccount;
  console.log(JSON.stringify({
    schema_version: 1,
    event: "api_probe_result",
    run_id: runId,
    started_at_utc: startedAt,
    completed_at_utc: new Date().toISOString(),
    duration_ms: response.timings.duration,
    success: healthy,
    status: response.status,
    operation: "account-list-read",
  }));
  check(response, {
    "DB-backed account list returned data": () => healthy,
  });
  probeLatency.add(response.timings.duration, {
    outcome: healthy ? "success" : "failure",
    status: String(response.status),
  });
  if (healthy) {
    probeSuccess.add(1);
  } else {
    probeFailure.add(1, { status: String(response.status) });
  }
}
