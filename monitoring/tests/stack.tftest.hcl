# Offline contract checks: no AWS calls and no real state access.
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
}

run "independent_server" {
  command = plan
  variables {
    plg_tempo_enabled = true
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
