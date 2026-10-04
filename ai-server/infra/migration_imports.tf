# 기존 infra state에서 AI 런타임 리소스를 분리하는 1회성 migration 기록입니다.
data "aws_caller_identity" "migration" {}
data "aws_partition" "migration" {}

locals {
  # 빈 destination state에서 ForceNew 필드가 unknown이 되지 않도록
  # 현재 source state 값을 고정합니다. Migration 완료 후 일반 참조로 복원합니다.
  migration_ai_instance_id           = "i-04ab95c711878616c"
  migration_ai_ami_id                = "ami-0ebb55ce78339fc0c"
  migration_ai_role_name             = "stockspoon-v1-ai-ec2-role"
  migration_ai_cloudwatch_policy_arn = "arn:${data.aws_partition.migration.partition}:iam::${data.aws_caller_identity.migration.account_id}:policy/stockspoon-v1-ai-cloudwatch-policy"
  migration_ai_ssm_policy_arn        = "arn:${data.aws_partition.migration.partition}:iam::${data.aws_caller_identity.migration.account_id}:policy/stockspoon-v1-ai-ssm-get-parameter"
}

import {
  to = aws_instance.ai
  id = local.migration_ai_instance_id
}

import {
  to = aws_eip.ai
  id = "eipalloc-0a88a344799153d96"
}

import {
  to = aws_eip_association.ai
  id = "eipassoc-0ece47b35be220565"
}

import {
  to = aws_security_group.ai
  id = "sg-0caa881fbbbcc8a9c"
}

import {
  to = aws_vpc_security_group_ingress_rule.ai_ssh["0.0.0.0/0"]
  id = "sgr-00c16a1a6cdad4ec8"
}

import {
  to = aws_vpc_security_group_ingress_rule.ai_api_from_app
  id = "sgr-05359fd6243d3fc2b"
}

import {
  to = aws_vpc_security_group_egress_rule.ai_all
  id = "sgr-027b625c2d7eb1ca7"
}

import {
  to = aws_iam_role.ai_ec2
  id = local.migration_ai_role_name
}

import {
  to = aws_iam_policy.ai_ssm_get_parameter
  id = local.migration_ai_ssm_policy_arn
}

import {
  to = aws_iam_role_policy_attachment.ai_ssm_get_parameter
  id = "${local.migration_ai_role_name}/${local.migration_ai_ssm_policy_arn}"
}

import {
  to = aws_iam_role_policy_attachment.ai_ssm_managed_instance
  id = "${local.migration_ai_role_name}/arn:${data.aws_partition.migration.partition}:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

import {
  to = aws_iam_instance_profile.ai_ec2
  id = "stockspoon-v1-ai-instance-profile"
}

import {
  for_each = local.ai_log_groups
  to       = aws_cloudwatch_log_group.ai[each.key]
  id       = each.value.name
}

import {
  to = aws_iam_policy.ai_cloudwatch
  id = local.migration_ai_cloudwatch_policy_arn
}

import {
  to = aws_iam_role_policy_attachment.ai_cloudwatch
  id = "${local.migration_ai_role_name}/${local.migration_ai_cloudwatch_policy_arn}"
}
