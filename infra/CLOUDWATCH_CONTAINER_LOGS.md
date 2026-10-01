# CloudWatch Logs for application containers

Terraform creates a seven-day log group for each long-running Compose service:

| Service | CloudWatch Logs group |
| --- | --- |
| Nginx | `/stockspoon/app/containers/nginx` |
| Frontend | `/stockspoon/app/containers/frontend` |
| Backend | `/stockspoon/app/containers/backend` |
| MySQL | `/stockspoon/app/containers/db` |

The former aggregate group, `/stockspoon/app/containers`, remains managed with
seven-day retention during migration so old log events are preserved. Docker's
`awslogs` driver sends each service's stdout/stderr directly to its own group in
`ap-northeast-2`. Stream names use the container name and short ID. The driver
uses `non-blocking` mode with a 4 MiB buffer; if CloudWatch is temporarily slow,
container writes continue while logs queue in memory, but records can be lost
if the buffer fills.

The CloudWatch Agent continues to collect host metrics and host logs. It does
not tail Nginx files. The official Nginx image forwards its access and error
logs to container stdout/stderr, which Docker sends to CloudWatch.

## Nginx access log fields

`nginx/conf.d/default.conf` writes access events as JSON. It records the time,
client and forwarded IPs, host, method, URI, HTTP status, bytes sent, request
duration, upstream address/status/duration, referer, and user agent. `status`
is numeric, so the Nginx 5xx metric filter matches responses from 500 through
599. `$request_time` and `$upstream_response_time` are durations in seconds;
upstream values can be `-` when no upstream was contacted, or comma-separated
when Nginx tried multiple upstreams.

These latency values are structured log fields, not separate CloudWatch metric
time series. Use Logs Insights to find slow or failing requests:

```sql
fields @timestamp, status, request_time, upstream_status,
       upstream_response_time, uri
| filter status >= 500 or request_time >= 1
| sort @timestamp desc
| limit 100
```

## Error metrics and alarms

Metric filters and alarms are separated by service. Nginx error-log severity
events and frontend, backend, and database error text each get their own
`Stockspoon/Logs` metric. Each service error alarm fires after at least five
matching log events in five minutes. Nginx also has a separate HTTP 5xx metric
and alarm that fires on the first 5xx response in a five-minute window.

The application error filters match the common `ERROR`, `Error`, and `error`
spellings. The Nginx filter matches its bracketed `error`, `crit`, `alert`, and
`emerg` severities. Metric filters count matching log events, not repeated
occurrences of a word within one event.

## Apply

1. Review a saved Terraform plan. The expected changes create per-service log
   groups, service-specific error filters/alarms, the Nginx HTTP 5xx
   filter/alarm, and update the EC2 role's log-publishing permissions. The old
   aggregate log group, filter, and alarm remain active during migration so
   existing containers keep their current alert path. Stop if the plan
   proposes destroying or replacing the application EC2, VPC, subnet, security
   group, EIP, or database volume.

   ```sh
   terraform -chdir=infra plan -out=app.service-logs.tfplan
   terraform -chdir=infra show -no-color app.service-logs.tfplan
   terraform -chdir=infra apply app.service-logs.tfplan
   ```

2. Deploy the updated `docker-compose.yaml` and Nginx config to the EC2 host.
   Compose-level logging settings take precedence over the Docker daemon's
   default logging configuration, so changing `/etc/docker/daemon.json` is not
   required for these four services.

3. Recreate the containers during a maintenance window so they adopt the new
   log groups and Nginx access format. This briefly restarts the selected
   services; the database data remains in the named `db-data` volume.

   ```sh
   docker compose up -d --force-recreate nginx frontend backend db
   ```

4. Confirm the new logging configuration and streams:

   ```sh
   docker ps -q | xargs -r docker inspect --format '{{.Name}} {{.HostConfig.LogConfig.Type}} {{json .HostConfig.LogConfig.Config}}'
   docker logs --tail 50 nginx
   ```

   Then inspect the four new groups in CloudWatch Logs. The old aggregate group
   filter/alarm should be removed in a later reviewed Terraform change after
   all containers have moved and the new alarms have been confirmed. The old
   aggregate group can be retained until its historical events are no longer
   needed.

## Buffer sizing

The 4 MiB buffer is the current baseline. Measure each service's peak
CloudWatch `IncomingBytes` during a load test or incident before increasing it.
Use short intervals to capture bursts. The published Moby benchmark is an
experiment, not a guarantee; its results depend on Docker version, log rate,
message sizes, and CloudWatch latency.
