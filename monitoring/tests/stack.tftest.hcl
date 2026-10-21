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
}
