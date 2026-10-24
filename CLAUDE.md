# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this repo is

Infrastructure for **Stock Spoon** (`stockspoon`), a mock stock-trading service, on AWS `ap-northeast-2`. It is almost entirely Terraform (pinned to **1.16.2** in CI), plus Python helper scripts, Lambda handlers, and DB-migration tooling. Application code (BE/FE/AI) lives in other repos; here they appear only as container images, task definitions, and compose files. Comments, docs, runbooks, and commit messages are written in Korean.

The platform is mid-migration from **V1** (EC2 + docker-compose, `docker-compose.yaml` / `scripts/deploy.sh` / `nginx/`) to **V2** (ECS Fargate in `ecs/`, ProxySQL on Fargate, Valkey, SQS, CloudFront FE). Both coexist; ALB weights split traffic between V1 and V2 backends.

## Terraform roots and dependencies

Each top-level directory is an independent Terraform root with its own S3 backend (several buckets: `stockspoon-terraform-state-v1`, `-v2`, `-redis`, `-sqs`, `-ai-dev`). There are no shared workspaces; roots read each other via `data "terraform_remote_state"` in `remote_state.tf`.

`.github/scripts/terraform_roots.py` is the source of truth for root order and dependencies:
- `ROOT_ORDER` — apply order.
- `DEPENDENTS` — which roots consume another root's outputs. Changing a root's outputs can break its dependents; CI plans them too.
- `MODULE_CONSUMERS` — roots that use `modules/` (currently only `modules/terraform-ci-policies` → `app-server`).

When adding a root, a remote-state reference, or a module consumer, update these maps (and `scripts/tests/test_terraform_roots.py`).

Remote-state references only go one way (e.g. `ecs` → `shared-infra`/`app-server`/`redis@prod`/`messaging@prod`/`ai-server/infra`; never the reverse). Cross-root security group rules live in the consuming root (`ecs/cross_root_rules.tf`).

**Multi-environment roots:** `redis` and `messaging` use a partial backend (`backend "s3" {}`) and are applied per environment with `environments/<dev|prod>/backend.hcl` and `terraform.tfvars.example`. Root IDs `redis@prod` / `messaging@prod` mean the prod env; bare names mean dev. All other roots are single-environment with a hard-coded backend.

Key roots:
- `shared-infra` — VPC/subnets.
- `app-server` — V1 EC2 app, ALB, Route53/ACM, FE CloudFront/S3, GitHub OIDC + Terraform CI roles, DB migration hosts (`db_migration*.tf`, `db-migration/`).
- `ecs` — V2 Fargate cluster and services (`svc_*.tf`: backend, frontend, market-http/common, proxysql), canary + auto-rollback Lambda (`backend_rollback.tf`, `lambda/`), observability. See `ecs/*.md`.
- `redis`, `messaging` — Valkey cache and SQS (DB-write replay queue + forwarder Lambda).
- `iam`, `storage`, `ecr`, `test-infra` (load-test/k6 infra), `ai-server/{infra,dev-infra,dashboard}`.

## Commands

Terraform (from repo root):
```bash
terraform -chdir=<root> fmt -check -recursive
terraform -chdir=<root> init -backend=false -input=false -lockfile=readonly   # offline validate
terraform -chdir=<root> validate
# multi-env roots:
terraform -chdir=redis init -reconfigure -backend-config=environments/prod/backend.hcl
terraform -chdir=redis plan -var-file=environments/prod/terraform.tfvars.example
```
`.github/scripts/terraform_plan.py <root-id>` reproduces CI's plan (fmt, init with the right backend config, artifact build, validate, plan, redacted summary). For `messaging` roots it first runs `messaging/lambda/build_db_write_replay_package.sh`.

Python tests are stdlib `unittest`; most load the module under test by file path, so run them from the repo root:
```bash
python3 -m unittest discover -s ecs/tests -v                       # run in CI
python3 -m unittest discover -s scripts/tests -v
python3 -m unittest discover -s app-server/db-migration/switchover/tests -v
cd messaging/lambda && python3 -m unittest test_db_write_replay_forwarder -v   # imports by module name
python3 -m unittest scripts.tests.test_terraform_roots.ModuleConsumersTest.test_policy_module_triggers_owner_and_remote_state_consumers  # single test
```

## CI

- `terraform-plan.yml` (PRs to `main`): detects affected roots (plus dependents) from the diff, runs `fmt -check` / `validate` per root, runs `ecs/tests` and `py_compile` on `.github/scripts`, then plans with a read-only OIDC role and posts one PR comment per root. `.md`/`.rst` changes don't trigger plans.
- `terraform-apply.yml` is currently **fully commented out**; applies are done manually.
- Lockfiles are used with `-lockfile=readonly`, so provider changes need an updated `.terraform.lock.hcl` committed.

## Conventions and gotchas

- Every root's `provider.tf` sets `default_tags` (`Project`, `Environment`, `ManagedBy`, `Stack`); keep them when adding roots.
- Secrets never go in Git: `*.tfvars`, `.env*` (except `.env.example`), tfstate, and plan files are ignored. V2 runtime secrets live in SSM Parameter Store under `/stockspoon/v2/prod/<service>/<KEY>` (load with `scripts/put-ssm-env.sh <service> <env-file>`); ECS task roles are scoped to that prefix.
- Some `tfplan` / `*.tfplan` files sit in root directories from local runs; they are gitignored artifacts, not inputs.
- DB switchover tooling (`app-server/db-migration/switchover/`) is run manually on the migration EC2; follow its `RUNBOOK.md`. Its tests mock all DB/AWS calls.
- PRs use `.github/PULL_REQUEST_TEMPLATE.md` (Korean sections: 작업 요약 / 작업 세부 내용 / 스크린샷 / 연관 이슈) and reference an issue (`closes #N`); branches are named like `feat/<issue>-<topic>`.
