# Database Primary Failover FIS

Issue: [#352](https://github.com/100-hours-a-week/KTB4-11th-Cloud/issues/352)

## Problem

Database Infra has two MySQL EC2 nodes using GTID and semi-synchronous replication. Replication Manager is intended to detect primary failure, promote the eligible replica, and update ProxySQL writer hostgroup 10. This experiment asks whether a single abrupt failure of the current writable DB host restores the tested application write path and preserves the tagged synthetic write set whose outcomes can be correlated across K6, Backend audit, and the promoted DB.

The DB nodes currently share one Availability Zone. This template does not test an AZ outage, ProxySQL failure, network delay, or a `mysqld`-only process failure. ProxySQL and Backend remain in the customer request path and are not fault targets.

## Falsifiable hypothesis

The hypothesis is testable only after a healthy baseline is verified: exactly one writable MySQL node; one eligible replica with I/O and SQL replication threads running and lag within the pre-agreed bound; semi-sync active on source and replica; Replication Manager authenticated to both DB nodes and reporting the expected topology; ProxySQL writer hostgroup 10 pointing only to the current primary; and a successful tagged write through the application path.

With that baseline, abruptly stopping the selected primary EC2 will result in all of the following:

1. Replication Manager detects the loss and promotes the eligible replica with the configured `failover-at-sync=true` policy.
2. ProxySQL routes writer hostgroup 10 to the promoted DB, and exactly one DB node is writable.
3. The tagged synthetic write path resumes within the RTO objective agreed before the run.
4. The promoted DB contains the complete recoverable point; confirmed tagged writes meet the RPO objective agreed before the run, and ambiguous outcomes remain explicitly unresolved.

The hypothesis fails if promotion or routing does not happen, there are zero or multiple writable nodes, tagged writes do not recover within the agreed RTO, or the reconciled data exceeds the agreed RPO. This repository does not set numeric RTO or RPO objectives. Semi-sync configuration alone does not prove zero loss: its configured 10-second acknowledgement timeout allows async fallback.

## RTO and RPO measurement contract

### RTO: customer write-path recovery

Measure the write path through ALB → Backend → ProxySQL → MySQL. For each tagged K6 write, correlate the run/write/request IDs, client request outcome and UTC timestamps with the Backend `db_migration_write_transaction` commit audit. The Backend repository owns that write workload and audit; the GET-only probe in this repository demonstrates a DB-backed read path and cannot prove write recovery.

Use FIS `action_start_time` as the recorded fault-injection reference. It is a control-plane timestamp and is not guaranteed to equal the instant the guest stopped serving requests. For customer impact, retain the first failed or timed-out write after that reference. Recovery is the first successful write in an interval that meets the latency and sustained-success criterion agreed before the run. Keep the first success and the time the sustained criterion is confirmed as separate timestamps. If the probe observes no write failures, report no customer-visible interruption in the sampled path rather than reporting a zero-second RTO. Report the probe interval and any uncertainty; do not label a read-only success as write-path recovery.

FIS schema-v2 `action-start`, `action-end`, and `action-error` events are written to the template's CloudWatch log group. The event record contains `event_timestamp`; the start/end details contain `action_start_time` and `action_end_time`. These events provide the injection timeline, not customer recovery time.

### RPO: last complete recoverable data point

RPO is an agreed maximum time interval from failure to the latest complete recoverable data point. For an experiment, compare the recorded failure-time reference with the UTC time of the last complete point that can be verified on the promoted DB. If the exact fault instant or the last complete point cannot be established, report a bounded interval or “undetermined” rather than false precision.

Separately reconcile the tagged write IDs from the K6 report and Backend audit against rows present on the promoted DB. Report confirmed missing IDs and ambiguous outcomes as separate counts; a missing HTTP response without Backend outcome evidence is not proof that a write was lost. Distinguish:

- K6 received a success response and Backend confirms the DB commit.
- Backend confirms acceptance or commit, but the client outcome is unknown.
- K6 received HTTP 202. Queue admission is not a synchronous DB commit; reconcile queue persistence and replay separately.
- The request failed before a DB commit was confirmed.

The Backend audit is opt-in for tagged K6 write IDs; it is not a durable ingress ledger for every production request. This experiment therefore evaluates the tagged synthetic write set, not all server-accepted customer writes. A claim covering every accepted customer write would require a durable record at the application acceptance boundary. Lost-write count, GTID position, replica lag, and the RPO time objective are different results; none substitutes for another.

## Existing observability

The existing DB FIS Grafana dashboard is used for infrastructure context and transition diagnosis: Hikari pending/acquire/timeout, ProxySQL connection failures and writer observations, MySQL writable-node count, replica threads/lag, semi-sync state, and Replication Manager events. These existing time series are sufficient; this experiment does not need additional Prometheus metrics to calculate the synthetic RTO/RPO when combined with FIS events, K6 results, Backend audit, and promoted-DB reconciliation.

FIS events stay in CloudWatch Logs. The monitoring Terraform grants the existing Grafana CloudWatch datasource read access to this specific FIS log group, so the timeline can be queried in Grafana Explore without shipping the same events into a second log store. The DB dashboard metrics diagnose transitions; they do not by themselves establish customer recovery or the data recovery point.

## Current readiness

On 2026-11-28 KST, the deployed Replication Manager task was revision 5. Its API returned `{"alive":"errors"}`, and both DB nodes continued transitioning to `ErrorAuth`. Replication Manager v3.1.48 maps MySQL error 1045 to that state. Its generated config matched the injected SSM secret, and a read-only MariaDB client in the same task authenticated directly to both DB nodes; a deliberately wrong password was rejected. The exact Replication Manager connection failure remains unresolved.

PR #354 fixed a real shell PID expansion defect, but revision 5 still reports `ErrorAuth`. Do not run this template until Replication Manager authenticates to both DB nodes, recognizes the topology, and the other readiness checks below pass. Healthy semi-sync/replication metrics at one point in time do not establish failover readiness.

## Template behavior and target safety

Terraform root: [`terraform/`](terraform/).

Terraform creates a manual-start FIS template, its execution role, a 30-day CloudWatch log group, and stop conditions using the existing Backend availability and target-5xx alarms. Terraform does not start an experiment. The action abruptly stops one EC2 instance using `skipOsShutdown=true` and schedules an EC2 restart after the configured stop interval (default 10 minutes). Skipping graceful shutdown may lose in-flight I/O or corrupt data. The stop interval is an injection setting, not an RTO objective.

The EC2 ID is an explicit Terraform input restricted to the two DB node IDs exported by `app-server` state. Terraform cannot determine MySQL's runtime role. Immediately before creating/updating the template and again before manually starting an experiment, verify that the selected ID is the current writer (`read_only=0`, `super_read_only=0`) and that the other node is the eligible replica. If the roles changed, update the input and template first.

Before a run, verify all of these:

1. Replication Manager is authenticated to both DB nodes, is in automatic mode, and recognizes the expected primary and eligible replica.
2. Semi-sync source/replica states are ON; both replica threads are running; replication/GTID lag meets the agreed baseline.
3. ProxySQL Admin is reachable by Replication Manager; writer hostgroup 10 contains only the current primary.
4. Tagged K6 writes and Backend commit audit are being captured outside the DB host, and a baseline tagged write succeeds through the customer path.
5. Both FIS stop alarms are `OK`; the recovery operator is available; the selected instance, data reconciliation window, and recovery procedure are recorded.

Do not start the template if a precondition fails. In particular, `ErrorAuth` means automatic failover has not been demonstrated.

## Provision the template

Copy [`terraform.tfvars.example`](terraform/terraform.tfvars.example) to a private `terraform.tfvars`, set the local AWS profile and the current writable DB instance ID, then run:

```sh
cd fis/database/terraform
terraform init
terraform plan
terraform apply
```

`terraform apply` provisions the template only. Start an experiment manually after the readiness checks and experiment window are approved. The template does not create an experiment result Markdown report; result collection and report automation are handled separately.
