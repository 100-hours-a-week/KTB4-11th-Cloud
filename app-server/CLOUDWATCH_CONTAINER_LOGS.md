# CloudWatch Logs for the application EC2

Docker Compose sends each service's stdout and stderr directly through the
Docker `awslogs` driver to its own log group:

- `/stockspoon/app/containers/nginx`
- `/stockspoon/app/containers/frontend`
- `/stockspoon/app/containers/backend`
- `/stockspoon/app/containers/db`

Terraform manages these four groups with seven-day retention. The former
aggregate group `/stockspoon/app/containers` is no longer managed. The local
CloudWatch Agent config collects host logs under `/stockspoon/app/system` and
host metrics; it does not collect container stdout/stderr.

## Remove the former aggregate group

Review the saved Terraform plan before applying. It should destroy only
`aws_cloudwatch_log_group.app_containers` among infrastructure resources. The
CloudWatch Agent IAM policy will also stop granting access to that former
group. Stop and review the plan if it proposes deleting or replacing the
application EC2, VPC, subnet, security group, EIP, or data volume.

```sh
terraform -chdir=infra plan -out=app.remove-aggregate-container-log-group.tfplan
terraform -chdir=infra show -no-color app.remove-aggregate-container-log-group.tfplan
terraform -chdir=infra apply app.remove-aggregate-container-log-group.tfplan
```

The old group's historical log export is saved locally at
`artifacts/cloudwatch-log-exports/stockspoon-app-containers-2026-09-30_1300-1400_KST.json`.

## Check the EC2 CloudWatch Agent

The Agent should only publish host logs to `/stockspoon/app/system`. Check its
configuration and status over SSH:

```sh
sudo /opt/aws/amazon-cloudwatch-agent/bin/amazon-cloudwatch-agent-ctl -a status
sudo grep -R -n -F '/stockspoon/app/containers' /opt/aws/amazon-cloudwatch-agent/etc
```

No grep result means the Agent is not configured to collect that container log
group, so no Agent change or restart is needed. If an old entry is found in
`/opt/aws/amazon-cloudwatch-agent/etc/config.json`, edit that file with `vi`,
remove only the matching object from `logs.logs_collected.files.collect_list`,
save, then reload the full config:

```sh
sudo vi /opt/aws/amazon-cloudwatch-agent/etc/config.json
sudo /opt/aws/amazon-cloudwatch-agent/bin/amazon-cloudwatch-agent-ctl \
  -a fetch-config \
  -m ec2 \
  -c file:/opt/aws/amazon-cloudwatch-agent/etc/config.json \
  -s
```

Container logs use Docker's logging driver, not the CloudWatch Agent. Confirm
the running containers point to the four service groups:

```sh
docker ps -q | xargs -r docker inspect --format '{{.Name}} {{.HostConfig.LogConfig.Type}} {{json .HostConfig.LogConfig.Config}}'
```

If `/etc/docker/daemon.json` still sets the former aggregate group as the
daemon-wide default, remove that stale `awslogs-group` configuration while
preserving unrelated Docker settings. Compose's per-service logging settings
take precedence. Existing containers keep their current logging configuration
until recreated, so recreate only a container that inspection shows is still
using the former group.
