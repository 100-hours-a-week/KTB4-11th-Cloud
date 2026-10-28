# Production market observability

## Scope

AI EC2: `market-streamer` metrics/traces and the existing host Alloy configuration.
ECS: `market-http` tracing configuration, deployed separately from the AI EC2.
No DB/schema, ASG, BE or FE resources are part of this change. No Terraform apply
is needed for the already reachable private Tempo endpoint.

## AI repository

Production Compose exposes the streamer exporter on host loopback port 9102.
The exporter must bind `0.0.0.0` inside the container. Scheduled `compose run`
must specify `--service-ports`; `--no-deps` prevents dependency-container changes.

Before a later deployment, set these nonsecret values in `PROD_AI_ENV`:

```dotenv
MARKET_STREAMER_OTEL_SDK_DISABLED=false
MARKET_STREAMER_OTEL_EXPORTER_OTLP_ENDPOINT=http://<private-tempo-ip>:4318
MARKET_STREAMER_OTEL_RESOURCE_ATTRIBUTES=deployment.environment=prod,deployment.environment.name=prod
```

The ECS CD renderer requires `OTEL_EXPORTER_OTLP_ENDPOINT` in
`MARKET_HTTP_ENV_JSON`, enables the native SDK, and disables OTLP metrics/logs.
Use the application's existing tracing implementation; no wrapper image is needed.
The `deliver` spans require sampled `traceparent` fields from a publisher and an
active SSE client. A successful exporter check alone does not validate that full path.

## Cloud repository

`render-deploy.py --target prod-ai-agent` includes streamer scraping on 9102
by default so later agent deployments keep the collection configuration.
Development market-http scraping stays opt-in.

`prepare-prod-streamer-observability.py` renders an SSM input document only. It
does not contact AWS or apply changes. It pins the production AI instance and
requires the current Alloy checksum. The installer backs up configuration,
validates it, restarts only Alloy, and leaves the scheduled streamer stopped.
The standalone Compose override requires `STREAMER_OTLP_ENDPOINT` when used
directly; the preparation tool substitutes its validated private endpoint.

Do not run a full AI CD workflow for this patch: it also runs the existing DB
migration steps. Review a service-only deployment separately.

## Verification and timing

During a scheduled run, check `up{job="market-streamer-metrics",environment="prod"}`
equals 1 and the event counters increase. The streamer exits at 15:40 KST; `up=0`
outside its 08:50–15:40 schedule is expected. Do not replace absence with a fake 1.
Test spans must be marked `diagnostic.synthetic=true`, with no Kiwoom or datastore
calls, and distinguished from actual `publish`/`deliver` traces.

## Work performed on 2026-10-28

Before the request to stop applying changes arrived, the AI EC2-only override,
systemd drop-in, and Alloy fragment were installed. Existing container IDs remained
unchanged. A disposable diagnostic container exposed zero-valued counters, reached
Prometheus with `up=1`, and exported `telemetry.configuration_check` to Tempo
(trace `432535391dfd5431a684ee4805e5c484`). No real market events were generated.
The smoke container used `--rm` and exited after 50 seconds; its eventual cleanup
was not rechecked after the stop instruction. Real scheduled ingestion and the
market-http `deliver` path still require a later approved verification.

The local repository changes after that instruction have not been deployed.
ECS market-http, DB, ASG, BE and FE were not modified remotely by this work.
The remote backup is
`/opt/stockspoon-ai-telemetry-agent/streamer-backup-20261028T135828Z`.
The pre-existing remote systemd drop-in takes precedence over the AI repository's
base unit. Review it when adopting the repository configuration; do not delete it
without an explicit deployment/rollback decision.
