# StockSpoon V2 messaging infrastructure

This Terraform root manages the SQS queues shared by the V2 Backend and AI
services. The first deployment target is `dev`. It also creates managed IAM
policies and the SQS consumer Lambdas. Compute stacks attach producer policies
to their EC2 or ECS roles. The SQS dashboard and DLQ alarms use a dedicated
Discord notifier Lambda in this stack.

## Dev queues

- `stockspoon-v2-dev-report-request`
- `stockspoon-v2-dev-report-dlq`
- `stockspoon-v2-dev-order.fifo`
- `stockspoon-v2-dev-order-dlq.fifo`
- `stockspoon-v2-dev-db-write-replay.fifo`
- `stockspoon-v2-dev-db-write-replay-dlq.fifo`

## Prod queues

The `prod` environment uses the same Terraform code with
`environments/prod/backend.hcl` and
`environments/prod/terraform.tfvars.example`.

- `stockspoon-v2-prod-report-request`
- `stockspoon-v2-prod-report-dlq`
- `stockspoon-v2-prod-order.fifo`
- `stockspoon-v2-prod-order-dlq.fifo`
- `stockspoon-v2-prod-db-write-replay.fifo`
- `stockspoon-v2-prod-db-write-replay-dlq.fifo`

Prod also creates the `stockspoon-v2-prod-backend-producer-sqs`,
`stockspoon-v2-prod-order-consumer-sqs`, `stockspoon-v2-prod-ai-sqs`,
`stockspoon-v2-prod-backend-db-write-replay-producer`, and
`stockspoon-v2-prod-db-write-replay-consumer` policies, the
`stockspoon-v2-prod-sqs` dashboard, DLQ alarms, the
`stockspoon-v2-prod-sqs-discord-notifier` and
`stockspoon-v2-prod-db-write-replay-forwarder` Lambdas, and empty Discord and
replay-token Secrets Manager secrets. Store each secret value outside
Terraform.

The DB write replay queue has a 14-day retention period, managed SQS encryption,
long polling, a 300-second visibility timeout and a FIFO dead-letter queue. The
producer policy permits only `sqs:SendMessage`; the consumer policy is attached
to a Lambda forwarder. The ECS root attaches the producer policy to the V2
Backend task role and must be applied after `messaging/prod` has published the
policy output.

The Lambda forwards each JSON business-command envelope to an authenticated
Backend replay endpoint over HTTPS. It does not execute SQL or connect directly
to MySQL/ProxySQL. Its SQS event source mapping is **disabled by default**, so
the queue continues to hold messages until the Backend replay endpoint is
implemented, deployed, configured, and the operator enables consumption. The
endpoint must replay the operation through Backend business logic using its
ProxySQL-backed datasource, authenticate the bearer token, and treat `requestId`
as an idempotency key. It must return 2xx only after the write commits or the
request is confirmed as already applied. Lambda failures leave the message for
SQS retry and eventual DLQ handling.

Before enabling the consumer:

1. Implement and deploy the Backend replay endpoint. It must accept the queued
   envelope and the `Idempotency-Key` header, and use the same ProxySQL-backed
   datasource as the Backend.
2. Store the same strong random bearer token in the environment's Secrets
   Manager secret (`db_write_replay_token_secret_name` output) and Backend
   configuration. Do not put the token in Terraform variables or source
   control.
3. Set `db_write_replay_endpoint_url` to the endpoint's HTTPS URL and
   `db_write_replay_consumer_enabled = true` in the environment's tfvars, then
   plan and apply. To start or stop draining without another Terraform apply,
   use the event-source mapping UUID output:

   ```bash
   aws lambda update-event-source-mapping \
     --uuid "$(terraform -chdir=messaging output -raw db_write_replay_event_source_mapping_uuid)" \
     --enabled \
     --region ap-northeast-2
   ```

   Pause it with `--no-enabled`. A later Terraform apply reconciles this setting
   to `db_write_replay_consumer_enabled`.

The mapping uses batch size 1 and the Lambda has reserved concurrency 1. The
producer must use the single global FIFO `MessageGroupId` documented below for
strict total order. SQS event delivery is at least once, so the Backend replay
endpoint must be idempotent; FIFO ordering alone does not prevent duplicates.

The FIFO producer must send a stable `MessageGroupId` for all writes if one
global order is required, and a unique `MessageDeduplicationId` per write. The
queue has content-based deduplication disabled so two legitimate writes with
identical bodies are not collapsed. FIFO ordering is per message group; a
message moved to the DLQ after repeated failures can leave later messages
available, so the replay worker must define how it handles that failure before
it is enabled.

Prod is applied only by the Terraform CD workflow as the `messaging@prod`
root. Do not run `terraform apply` for prod from a local machine.

## Dev IAM policies

- `stockspoon-v2-dev-backend-producer-sqs`
- `stockspoon-v2-dev-order-consumer-sqs`
- `stockspoon-v2-dev-ai-sqs`
- `stockspoon-v2-dev-backend-db-write-replay-producer`
- `stockspoon-v2-dev-db-write-replay-consumer`

The dev environment also creates the `stockspoon-v2-dev-db-write-replay-forwarder`
Lambda and the empty `stockspoon/v2/dev/db-write-replay/consumer-token` secret.

The Backend producer policy is not attached to a role in this stack; its ARN is
exposed for the ECS root to attach to the Backend task role. The DB write replay
consumer policy is attached to the Lambda execution role here. The other
producer and consumer policies remain available as outputs for their compute
stacks.

## Monitoring and Discord notifications

The CloudWatch dashboard shows the main queues' backlog, in-flight messages,
oldest message age, and throughput, including the DB write replay queue. Each
DLQ has an alarm that enters `ALARM`
when at least one visible message exists and returns to `OK` after the DLQ is
empty.

The alarms invoke the dedicated `stockspoon-v2-dev-sqs-discord-notifier`
Lambda. This stack creates the empty
`stockspoon/v2/dev/sqs/discord-webhook` Secrets Manager secret but deliberately
does not manage a secret value. After apply, store a newly generated Discord
webhook URL directly in that secret outside Terraform. Never commit the URL or
pass it as a Terraform variable.

## Validation without a remote backend

```bash
terraform -chdir=messaging fmt -check -recursive
terraform -chdir=messaging init -backend=false
terraform -chdir=messaging validate
```

`validate` works without configuring the S3 backend. Planning and applying
require the real dev state bucket.

## Dev plan

The dev state is stored in the pre-created
`stockspoon-terraform-state-sqs` S3 bucket under the
`messaging/dev/terraform.tfstate` key. Initialize it with:

```bash
terraform -chdir=messaging init \
  -reconfigure \
  -backend-config=environments/dev/backend.hcl

terraform -chdir=messaging plan \
  -var-file=environments/dev/terraform.tfvars.example
```

## Switching environments locally

Dev and prod share this directory and its `.terraform` working directory.
Always pass `-reconfigure` with the matching backend file, and pair it with the
var file of the same environment. Mixing a prod backend with the dev var file
plans to rename every prod resource.

```bash
terraform -chdir=messaging init \
  -reconfigure \
  -backend-config=environments/prod/backend.hcl

terraform -chdir=messaging plan \
  -var-file=environments/prod/terraform.tfvars.example
```

AWS credentials must come from an AWS profile or an assumed CI role. Do not
put access keys in Terraform or backend configuration files.
