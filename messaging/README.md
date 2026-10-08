# StockSpoon V2 messaging infrastructure

This Terraform root manages the SQS queues shared by the V2 Backend and AI
services. The first deployment target is `dev`; ECS roles, IAM policies, and
CloudWatch alarms are added in later stages.

## Dev queues

- `stockspoon-v2-dev-report-request`
- `stockspoon-v2-dev-report-dlq`
- `stockspoon-v2-dev-order.fifo`
- `stockspoon-v2-dev-order-dlq.fifo`

## Validation without a remote backend

```bash
terraform -chdir=messaging fmt -check -recursive
terraform -chdir=messaging init -backend=false
terraform -chdir=messaging validate
```

`validate` works without configuring the S3 backend. Planning and applying
require the real dev state bucket.

## Dev plan

Replace the placeholder bucket in
`environments/dev/backend.hcl.example`, save the approved configuration as
`environments/dev/backend.hcl`, and run:

```bash
terraform -chdir=messaging init \
  -reconfigure \
  -backend-config=environments/dev/backend.hcl

terraform -chdir=messaging plan \
  -var-file=environments/dev/terraform.tfvars.example
```

AWS credentials must come from an AWS profile or an assumed CI role. Do not
put access keys in Terraform or backend configuration files.
