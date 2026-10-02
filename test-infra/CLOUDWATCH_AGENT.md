# CloudWatch Agent for the load-test EC2 instances

This setup uses CloudWatch for infrastructure telemetry without adding a
monitoring EC2. The Docker Compose `awslogs` driver continues to send nginx,
frontend, backend, and database container stdout/stderr to the log groups
already configured for those services. The CloudWatch Agent config in this
directory is for app and k6 host metrics, cloud-init output, system journal
entries, and the Agent's own diagnostic log; it does not collect container
logs a second time.

The Agent publishes metrics to the `CWAgent` namespace every 60 seconds:

- CPU active and I/O wait
- Memory used percentage
- Root disk used percentage and disk I/O
- Network bytes, dropped packets, and errors
- Running process count

Metrics include `InstanceId` and `InstanceType` dimensions, so app and k6
measurements remain distinguishable. Host logs go to
`/stockspoon/loadtest/system`, with separate streams named by instance ID. The
log group has 14-day retention and is managed by Terraform.

## 1. Apply the IAM and log-group changes

The app and k6 instance profiles need permission to publish the `CWAgent`
namespace and write to the test system log group. `iam.tf` and
`monitoring.tf` define those permissions and the log group. Run Terraform from
this directory before installing the Agent:

```sh
terraform init
terraform plan -out=cloudwatch-agent.tfplan
terraform show -no-color cloudwatch-agent.tfplan
```

The plan should add the test system log group and update the two EC2 role
policies. It should not replace either EC2 instance or change the VPC, subnet,
route, security groups, or EIP. If it proposes those changes, stop and review
the plan. After reviewing it, apply with:

```sh
terraform apply cloudwatch-agent.tfplan
```

## 2. Copy the config to each EC2

Use the existing `stockspoon-v1-deploy` private key. From the Cloud repository
root, copy the same JSON to the app host and k6 host:

```sh
scp -i /path/to/stockspoon-v1-deploy.pem \
  test-infra/cloudwatch-agent.json \
  ubuntu@<APP_PUBLIC_IP>:/tmp/cloudwatch-agent.json

scp -i /path/to/stockspoon-v1-deploy.pem \
  test-infra/cloudwatch-agent.json \
  ubuntu@<K6_PUBLIC_IP>:/tmp/cloudwatch-agent.json
```

Replace the example key path and public IPs with the values for the two
instances. The config is identical on both; CloudWatch Agent resolves the
instance ID at runtime.

## 3. Install and start the Agent on each EC2

SSH to one instance and run the following commands. Repeat on the other
instance after copying the JSON there:

```sh
sudo apt-get update
sudo apt-get install -y ca-certificates curl
curl --fail --silent --show-error --location \
  "https://amazoncloudwatch-agent.s3.amazonaws.com/ubuntu/amd64/latest/amazon-cloudwatch-agent.deb" \
  --output /tmp/amazon-cloudwatch-agent.deb
sudo dpkg -i -E /tmp/amazon-cloudwatch-agent.deb

sudo install -o root -g root -m 0644 \
  /tmp/cloudwatch-agent.json \
  /opt/aws/amazon-cloudwatch-agent/etc/stockspoon-loadtest-cloudwatch-agent.json
sudo /opt/aws/amazon-cloudwatch-agent/bin/amazon-cloudwatch-agent-ctl \
  -a fetch-config \
  -m ec2 \
  -c file:/opt/aws/amazon-cloudwatch-agent/etc/stockspoon-loadtest-cloudwatch-agent.json \
  -s
sudo /opt/aws/amazon-cloudwatch-agent/bin/amazon-cloudwatch-agent-ctl -a status
```

For startup diagnostics, inspect the Agent service and its own log:

```sh
sudo systemctl status amazon-cloudwatch-agent --no-pager
sudo journalctl -u amazon-cloudwatch-agent -n 100 --no-pager
sudo tail -n 100 /opt/aws/amazon-cloudwatch-agent/logs/amazon-cloudwatch-agent.log
```

## 4. Confirm telemetry

In the AWS console, select `ap-northeast-2`:

1. In **CloudWatch → Metrics → CWAgent**, filter by each EC2 `InstanceId`.
   Expect CPU `used_percent`, `cpu_usage_iowait`, `mem_used_percent`,
   `disk_used_percent`, disk I/O, network, and process metrics.
2. In **CloudWatch Logs → Log groups**, open
   `/stockspoon/loadtest/system` and confirm streams for both instance IDs.
3. The existing Compose `awslogs` streams remain the source for container
   stdout/stderr. Keep them separate from the Agent's host/system stream.

If metrics or logs do not appear, first check the Agent status, the instance
profile policy, region, and whether the log group was created by Terraform.
The instance must have HTTPS egress to the CloudWatch endpoints; these test
instances are in a public subnet with an Internet Gateway route.

## Load-test SLI note

The CloudWatch Agent provides host-level context for a run. It does not
calculate the report endpoint's success-rate or three-second SLI. Use k6's
request results and response-body checks for those two SLI calculations, then
correlate the run time with the app and k6 EC2 metrics and CloudWatch Logs.
