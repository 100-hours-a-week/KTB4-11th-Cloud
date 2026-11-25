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
      --env DURATION=20m \
      --out json=/tmp/db-path-rto.json \
      loadtest/fis-probe/db-path-rto.js

The default rate is fixed at one request per second and the request timeout is
three seconds. The script does not print or tag the JWT. Keep the token file
outside the repository and remove it after the run.

The JSON output has timestamps for individual k6 metric samples. Grafana's
Backend API p95 panel is useful for the request-latency trend, while the k6
samples provide finer per-request timestamps for RTO calculation.

Do not set a pass/fail threshold for this probe during a fault experiment:
failed requests are expected evidence during the injected outage.
