# AI 런타임 리소스를 ai-server/infra state로 이전하기 위한 기록입니다.
# destroy = false이므로 기존 infra state에서만 관리 연결을 제거합니다.
removed {
  from = aws_instance.ai

  lifecycle {
    destroy = false
  }
}

removed {
  from = aws_eip.ai

  lifecycle {
    destroy = false
  }
}

removed {
  from = aws_eip_association.ai

  lifecycle {
    destroy = false
  }
}

removed {
  from = aws_security_group.ai

  lifecycle {
    destroy = false
  }
}

removed {
  from = aws_vpc_security_group_ingress_rule.ai_ssh

  lifecycle {
    destroy = false
  }
}

removed {
  from = aws_vpc_security_group_ingress_rule.ai_api_from_app

  lifecycle {
    destroy = false
  }
}

removed {
  from = aws_vpc_security_group_egress_rule.ai_all

  lifecycle {
    destroy = false
  }
}

removed {
  from = aws_iam_role.ai_ec2

  lifecycle {
    destroy = false
  }
}

removed {
  from = aws_iam_policy.ai_ssm_get_parameter

  lifecycle {
    destroy = false
  }
}

removed {
  from = aws_iam_role_policy_attachment.ai_ssm_get_parameter

  lifecycle {
    destroy = false
  }
}

removed {
  from = aws_iam_role_policy_attachment.ai_ssm_managed_instance

  lifecycle {
    destroy = false
  }
}

removed {
  from = aws_iam_instance_profile.ai_ec2

  lifecycle {
    destroy = false
  }
}

removed {
  from = aws_cloudwatch_log_group.ai

  lifecycle {
    destroy = false
  }
}

removed {
  from = aws_iam_policy.ai_cloudwatch

  lifecycle {
    destroy = false
  }
}

removed {
  from = aws_iam_role_policy_attachment.ai_cloudwatch

  lifecycle {
    destroy = false
  }
}
