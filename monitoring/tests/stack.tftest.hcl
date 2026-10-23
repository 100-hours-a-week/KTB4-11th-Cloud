# Offline contract checks: no AWS calls and no real state access.
# Explicit values keep local *.auto.tfvars from changing test scenarios.
variables {
  plg_tempo_enabled     = false
  dev_telemetry_enabled = false
  dev_ai_telemetry_enabled  = false
  prod_ai_telemetry_enabled = false
  grafana_domain_name   = ""
}

override_data {
  target = data.terraform_remote_state.development_ai
  values = {
    outputs = {
      ai_instance_id       = "i-01111111111111111"
      ai_private_ip        = "10.20.1.61"
      ai_security_group_id = "sg-01111111111111111"
    }
  }
}

override_data {
  target = data.terraform_remote_state.production_ai
  values = {
    outputs = {
      ai_instance_id       = "i-02222222222222222"
      ai_private_ip        = "10.0.1.50"
      ai_security_group_id = "sg-02222222222222222"
    }
  }
}

override_data {
  target = data.aws_instance.ai["dev"]
  values = { private_ip = "10.20.1.61", subnet_id = "subnet-0fedcba9876543210" }
}

override_data {
  target = data.aws_instance.ai["prod"]
  values = { private_ip = "10.0.1.50", subnet_id = "subnet-0123456789abcdef0" }
}

override_data {
  target = data.aws_subnet.ai["dev"]
  values = { id = "subnet-0fedcba9876543210", vpc_id = "vpc-0fedcba9876543210" }
}

override_data {
  target = data.aws_subnet.ai["prod"]
  values = { id = "subnet-0123456789abcdef0", vpc_id = "vpc-0123456789abcdef0" }
}

mock_provider "aws" {
  mock_data "aws_caller_identity" {
    defaults = { account_id = "123456789012" }
  }
  mock_data "aws_partition" {
    defaults = { partition = "aws" }
  }
  mock_data "aws_ssm_parameter" {
    defaults = { value = "ami-0123456789abcdef0" }
  }
  mock_data "aws_subnet" {
    defaults = { availability_zone = "ap-northeast-2a" }
  }
  mock_data "aws_iam_policy_document" {
    defaults = {
      json = "{\"Version\":\"2012-10-17\",\"Statement\":[{\"Effect\":\"Allow\",\"Action\":\"sts:AssumeRole\",\"Principal\":{\"Service\":\"ec2.amazonaws.com\"}}]}"
    }
  }
  mock_resource "aws_s3_bucket" {
    defaults = { arn = "arn:aws:s3:::test-monitoring" }
  }
  mock_resource "aws_iam_role" {
    defaults = { arn = "arn:aws:iam::123456789012:role/test-monitoring" }
  }
  mock_resource "aws_instance" {
    defaults = { private_ip = "10.0.11.236" }
  }
  mock_data "aws_vpc_peering_connection" {
    defaults = {
      status      = "active"
      vpc_id      = "vpc-0123456789abcdef0"
      peer_vpc_id = "vpc-0fedcba9876543210"
    }
  }
  mock_data "aws_route53_zone" {
    defaults = { zone_id = "Z1234567890ABCDE" }
  }
  mock_resource "aws_acm_certificate" {
    defaults = {
      arn = "arn:aws:acm:ap-northeast-2:123456789012:certificate/01234567-89ab-cdef-0123-456789abcdef"
      domain_validation_options = [{
        domain_name           = "monitoring.stock-spoon.com"
        resource_record_name  = "_validation.monitoring.stock-spoon.com."
        resource_record_type  = "CNAME"
        resource_record_value = "_validation.acm-validations.aws."
      }]
    }
  }
}

override_data {
  target = data.terraform_remote_state.development
  values = {
    outputs = {
      vpc_id                    = "vpc-0fedcba9876543210"
      public_subnet_id          = "subnet-0fedcba9876543210"
      dev_app_instance_id       = "i-0fedcba9876543210"
      dev_app_private_ip        = "10.20.1.42"
      dev_app_security_group_id = "sg-0fedcba9876543210"
    }
  }
}

override_data {
  target = data.terraform_remote_state.shared
  values = {
    outputs = {
      vpc_id             = "vpc-0123456789abcdef0"
      private_subnet_ids = ["subnet-0123456789abcdef0"]
    }
  }
}

override_data {
  target = data.terraform_remote_state.app_edge
  values = {
    outputs = {
      alb_dns_name          = "stockspoon-v1-alb.example.ap-northeast-2.elb.amazonaws.com"
      alb_zone_id           = "Z35SXDOTRQ7X7K"
      alb_security_group_id = "sg-0123456789abcdef0"
      https_listener_arn    = "arn:aws:elasticloadbalancing:ap-northeast-2:123456789012:listener/app/stockspoon-v1-alb/0123456789abcdef/0123456789abcdef"
    }
  }
}

run "disabled_by_default" {
  command = plan
  assert {
    condition     = length(aws_instance.telemetry) == 0 && length(aws_ebs_volume.telemetry) == 0 && length(aws_s3_bucket.telemetry) == 0
    error_message = "The default configuration must not create monitoring infrastructure."
  }
  assert {
    condition     = output.plg_tempo == null
    error_message = "A disabled stack must not advertise an available monitoring server."
  }
  assert {
    condition     = length(aws_vpc_peering_connection.development) == 0 && length(aws_route.development_to_telemetry) == 0 && output.development_telemetry == null
    error_message = "Development networking must remain opt-in."
  }
}

run "independent_server" {
  command = plan
  variables {
    plg_tempo_enabled = true
  }
  assert {
    condition     = aws_ssm_parameter.development_discord_webhook["app"].type == "SecureString" && output.development_discord_webhook_parameters.app == "/stockspoon/monitoring/dev/app/discord-webhook" && output.development_discord_webhook_parameters.ai == "/stockspoon/monitoring/dev/ai/discord-webhook"
    error_message = "Development Discord must have its own encrypted parameter, with only its name exposed as an output."
  }
  assert {
    condition     = length(aws_instance.telemetry) == 1 && length(aws_ebs_volume.telemetry) == 1 && length(aws_s3_bucket.telemetry) == 2
    error_message = "The independent root must plan one server, one persistent disk and separate log/trace buckets."
  }
  assert {
    condition     = !aws_instance.telemetry[0].associate_public_ip_address
    error_message = "The monitoring server must remain private."
  }
  assert {
    condition     = length(aws_route53_record.grafana) == 0 && length(aws_lb_listener_rule.grafana) == 0
    error_message = "Public Grafana routing must be opt-in."
  }
}

run "grafana_hostname" {
  command = plan
  variables {
    plg_tempo_enabled   = true
    grafana_domain_name = "monitoring.stock-spoon.com"
  }
  assert {
    condition     = aws_route53_record.grafana[0].name == "monitoring.stock-spoon.com" && length(aws_acm_certificate.grafana) == 1
    error_message = "The public hostname requires a dedicated DNS record and certificate."
  }
  assert {
    condition     = aws_lb_listener_rule.grafana[0].priority < 100 && aws_lb_target_group.grafana[0].port == 3000
    error_message = "The host route must reach Grafana before general application API rules."
  }
  assert {
    condition     = !aws_instance.telemetry[0].associate_public_ip_address && aws_vpc_security_group_ingress_rule.grafana_from_alb[0].referenced_security_group_id == "sg-0123456789abcdef0"
    error_message = "Grafana stays private and accepts port 3000 only from the ALB security group."
  }
}

run "development_private_collection" {
  command = plan
  variables {
    plg_tempo_enabled     = true
    dev_telemetry_enabled = true
  }
  assert {
    condition     = length(aws_vpc_peering_connection.development) == 1 && aws_vpc_peering_connection.development[0].auto_accept
    error_message = "Development collection requires a same-account private peering connection."
  }
  assert {
    condition     = aws_route.telemetry_to_development[0].destination_cidr_block == "10.20.1.42/32"
    error_message = "Return routing must be limited to the dedicated development application host."
  }
  assert {
    condition     = toset([for rule in aws_vpc_security_group_ingress_rule.development_telemetry : rule.from_port]) == toset([3100, 9090, 4318]) && alltrue([for rule in aws_vpc_security_group_ingress_rule.development_telemetry : rule.referenced_security_group_id == "sg-0fedcba9876543210"])
    error_message = "Only the development app SG may access logs, metrics and OTLP/HTTP."
  }
  assert {
    condition     = output.development_telemetry.environment == "dev" && output.development_telemetry.instance_id == "i-0fedcba9876543210"
    error_message = "The deployment target must be the development host, never the load-test host."
  }
}

run "reuse_development_peering" {
  command = plan
  variables {
    plg_tempo_enabled             = true
    dev_telemetry_enabled         = true
    dev_vpc_peering_connection_id = "pcx-0123456789abcdef0"
  }
  assert {
    condition     = length(aws_vpc_peering_connection.development) == 0 && aws_route.development_to_telemetry[0].vpc_peering_connection_id == "pcx-0123456789abcdef0"
    error_message = "A supplied peering connection must be reused without creating a duplicate."
  }
}

run "collect_existing_ai_hosts" {
  command = plan
  variables {
    plg_tempo_enabled        = true
    dev_telemetry_enabled    = true
    dev_ai_telemetry_enabled = true
    prod_ai_telemetry_enabled = true
  }
  assert {
    condition     = length(aws_instance.telemetry) == 1 && length(data.aws_instance.ai) == 2 && length(aws_vpc_security_group_ingress_rule.ai_telemetry) == 4
    error_message = "AI collection must reuse both existing hosts and open only two private ingestion ports per host."
  }
  assert {
    condition     = aws_route.telemetry_to_development_ai[0].destination_cidr_block == "10.20.1.61/32"
    error_message = "The development AI return route must be limited to its single private address."
  }
  assert {
    condition     = output.ai_telemetry.dev.environment == "dev" && output.ai_telemetry.prod.environment == "prod" && output.ai_telemetry.prod.cluster == "stockspoon-v1-ai"
    error_message = "The existing V1 AI host remains production, separate from development AI."
  }
}
