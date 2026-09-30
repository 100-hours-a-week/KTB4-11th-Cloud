# CloudWatch Logs for Docker containers

Terraform creates `/stockspoon/app/containers` with seven-day retention and
grants the EC2 instance profile permission to create streams and publish log
events only in that group. The `awslogs` driver sends container stdout/stderr
directly to CloudWatch Logs; the CloudWatch Agent continues to collect host
metrics, cloud-init logs, the CloudWatch Agent's own log, and info-or-higher
system journal entries. Journald collection includes all systemd units, so
Docker daemon and host service messages are included when they reach the
journal.

The Docker daemon configuration to merge into `/etc/docker/daemon.json` is in
`docker-daemon-cloudwatch-logging.json`. It gives each container a stream named
from its name and short ID, and uses a 4 MiB non-blocking buffer so a logging
backlog does not block the application. If that buffer fills, new log messages
can be dropped.

## Apply

1. Review the Terraform plan and apply it before changing Docker. The planned
   change should not replace or destroy the application EC2 instance. If the
   plan shows an EC2, VPC, subnet, security group, EIP, or data-volume destroy,
   stop and review the plan instead of applying it.

   ```sh
   terraform -chdir=infra plan -out=app.container-logs.tfplan
   terraform -chdir=infra show -no-color app.container-logs.tfplan
   terraform -chdir=infra apply app.container-logs.tfplan
   ```

2. SSH to the application EC2 and inspect the current Docker logging
   configuration before changing it:

   ```sh
   sudo cat /etc/docker/daemon.json
   docker info --format '{{.LoggingDriver}}'
   docker ps -q | xargs -r docker inspect --format '{{.Name}} {{.HostConfig.LogConfig.Type}}'
   ```

3. Copy `infra/docker-daemon-cloudwatch-logging.json` to the EC2. Merge its
   `log-driver` and `log-opts` keys into `/etc/docker/daemon.json`; preserve any
   existing Docker daemon settings. If the application Compose file sets a
   service-level `logging:` driver, update or remove that override too, because
   it takes precedence over the daemon default.

4. At a time when a brief application restart is acceptable, restart Docker
   and recreate the Compose containers so they adopt the new logging driver:

   ```sh
   sudo systemctl restart docker
   cd <directory-containing-compose.yaml>
   docker compose up -d --force-recreate
   ```

5. Confirm each recreated container reports `awslogs`, then check the
   `/stockspoon/app/containers` log group in CloudWatch Logs. Existing
   containers keep their previous logging driver until they are recreated.

The generic `ERROR` metric filter now reads the container log group, so the
existing application log-error alarm can count container errors. The storage
device error filter remains attached to `/stockspoon/app/system`.

## Apply CloudWatch Agent metric and log changes

The Agent configuration now publishes `mem_used_percent` instead of
`mem_available_percent`. It also collects system journal entries at `info`
priority and above, plus the Agent's own diagnostic log. From the repository
root on your local machine, copy the full config to EC2:

```sh
scp -i <key.pem> infra/cloudwatch-agent.json ubuntu@<EC2_PUBLIC_IP>:/tmp/cloudwatch-agent.json
```

Then SSH to EC2 and apply the full configuration (including the existing
metrics and host log sources):

```sh
sudo install -m 0644 /tmp/cloudwatch-agent.json /opt/aws/amazon-cloudwatch-agent/etc/config.json
sudo /opt/aws/amazon-cloudwatch-agent/bin/amazon-cloudwatch-agent-ctl \
  -a fetch-config \
  -m ec2 \
  -c file:/opt/aws/amazon-cloudwatch-agent/etc/config.json \
  -s
```

The memory alarm and USE dashboard now use `mem_used_percent`; the alarm is
85% or higher for three of five one-minute periods. `mem_used_percent` and
`mem_available_percent` use different Linux memory calculations, so this is a
metric change rather than an exact rename of the previous alarm.
