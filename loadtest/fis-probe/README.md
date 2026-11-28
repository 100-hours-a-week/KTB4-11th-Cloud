# DB path RTO probe

This read-only k6 probe sends one authenticated request per second to
GET /api/v1/users/me/accounts. The Backend reads the account list through its
configured datasource, so each successful response confirms the tested
ALB → Backend → ProxySQL → DB path returned application data.

The probe writes request-level k6 samples to a local JSON output file. Use the
time of the first successful response after a failed response as the observed
service-recovery time. ECS STOPPED and replacement RUNNING events explain
the Task lifecycle; they do not by themselves prove the application can serve
DB-backed requests.

## Run

Create a protected file containing one currently valid JWT, then run:

    k6 run \
      --env API_BASE_URL=https://stock-spoon.com \
      --env DB_FIS_PROBE_TOKEN_FILE=/secure/path/db-fis-probe.jwt \
      --env DB_FIS_RUN_ID=db-fis-<unique-id> \
      --env DURATION=20m \
      --log-format raw --console-output /tmp/db-path-rto.api.jsonl \
      --out json=/tmp/db-path-rto.json \
      loadtest/fis-probe/db-path-rto.js

The default rate is fixed at one request per second and the request timeout is
three seconds. The script does not print or tag the JWT. Keep the token file
outside the repository and remove it after the run.

The JSON output has timestamps for individual k6 metric samples. Grafana's
Backend API p95 panel is useful for the request-latency trend, while the k6
samples provide finer per-request timestamps for RTO calculation.

The separate console JSONL records `run_id`, request start/completion UTC time,
duration, status, operation, and success. It never contains a JWT or response
body. Use an explicit run ID to correlate it with FIS and Repman events. Keep
the first successful response and the beginning/confirmation of a sustained
healthy interval as separate timestamps. Define the required healthy duration
and latency limit before running; a gap or dropped iteration is not success.
This GET probe cannot establish SQL commit recovery or RPO. See
`fis/database/OBSERVABILITY.md` for the measurement contract.

Do not set a pass/fail threshold for this probe during a fault experiment:
failed requests are expected evidence during the injected outage.
