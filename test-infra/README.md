# Load-test infrastructure

This directory owns the separate load-test VPC and its two EC2 instances. The same VPC is also reused as the StockSpoon V2 development network. Its Terraform state is stored under the separate S3 object key test-infra/terraform.tfstate, so it does not share the production infra state key.

## Resources

- A new VPC using 10.20.0.0/16, a public subnet, an Internet Gateway, and a default route. Confirm that this CIDR does not overlap any other VPC or connected network before applying.
- Two shared development private subnets, `10.20.10.0/24` in `ap-northeast-2a` and `10.20.11.0/24` in `ap-northeast-2c`. Their dedicated route table has only the VPC local route and no Internet Gateway or NAT Gateway route.
- An application EC2 sized like the current V1 host by default. It gets a stable Elastic IP, Docker and Docker Compose, and the Cloud repository cloned under /opt/cloud.
- A k6 EC2 with k6 installed from Grafana's official Debian/Ubuntu package repository.
- Separate security groups and EC2 instance profiles. HTTP and HTTPS reach the test app publicly. Both EC2s use the existing stockspoon-v1-deploy key pair. SSH is allowed from 0.0.0.0/0 by default, matching infra; set ssh_allowed_cidrs to your public IP /32 to narrow access. SSM remains available as an optional fallback.
- The application EC2 can write to the existing StockSpoon application CloudWatch log groups used by docker-compose.yaml.
- CloudWatch Agent IAM permissions and a 14-day test system log group for app and k6 host metrics/system logs. See [CLOUDWATCH_AGENT.md](CLOUDWATCH_AGENT.md) for the manual Agent installation steps and [cloudwatch-agent.json](cloudwatch-agent.json) for the shared config.

The application bootstrap prepares the same Docker host deployment environment used by infra, but it does not start the application stack or inject application secrets. Configure the test host's .env and deploy the desired FE/BE images through the existing deployment process after provisioning.

## SSH access

After apply, use the existing private key file for either instance:

    ssh -i /path/to/stockspoon-v1-deploy.pem ubuntu@$(terraform output -raw app_public_ip)
    ssh -i /path/to/stockspoon-v1-deploy.pem ubuntu@$(terraform output -raw k6_public_ip)

Replace the example path with the local path to your key file. The EC2 key pair name is already set to stockspoon-v1-deploy.

## Before applying

The remote backend expects the existing S3 state bucket stockspoon-terraform-state-v1. The EC2 key pair defaults to stockspoon-v1-deploy. Set ssh_allowed_cidrs to your public IP /32 in a local terraform.tfvars file if you want to restrict SSH ingress. The default instance sizes are both t3a.medium; adjust them to fit the planned load before creating resources.

Run from this directory:

    terraform init
    terraform plan
    terraform apply

Useful outputs include app_public_ip, app_private_ip, k6_public_ip, k6_app_private_url, private_subnet_ids, and private_route_table_id. Valkey and future development services consume private_subnet_ids through Terraform Remote State.
