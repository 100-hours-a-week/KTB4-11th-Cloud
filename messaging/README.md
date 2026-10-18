# StockSpoon V2 messaging infrastructure

This Terraform root manages the SQS queues shared by the V2 Backend and AI
services. The first deployment target is `dev`. It also creates the managed
IAM policies that will be attached to future EC2 or ECS roles; role creation
and policy attachment remain with the compute stacks. The SQS dashboard and
DLQ alarms use a dedicated Discord notifier Lambda in this stack.

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
`stockspoon-v2-prod-sqs-discord-notifier` Lambda, and the empty
`stockspoon/v2/prod/sqs/discord-webhook` secret. Store a prod-only Discord
webhook URL in that secret after the first apply.

The DB write replay queue has a 14-day retention period, managed SQS encryption,
long polling, a 300-second visibility timeout and a FIFO dead-letter queue. The
producer policy permits only `sqs:SendMessage`; the consumer policy is prepared
for the future replay worker and is not attached to a Lambda yet. The ECS root
attaches the producer policy to the V2 Backend task role and must be applied
after `messaging/prod` has published the policy output. This infrastructure does
not consume or replay messages by itself.

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

The policies are not attached to a role in this stack. Their ARNs are exposed
as Terraform outputs for a future EC2 instance role or ECS task role. A single
development EC2 role can attach both Backend policies; separate ECS tasks can
attach only the producer or consumer policy they require.

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
