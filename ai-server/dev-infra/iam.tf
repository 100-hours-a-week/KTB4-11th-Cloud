data "aws_caller_identity" "current" {}

data "aws_partition" "current" {}

data "aws_iam_policy_document" "ai_ec2_assume_role" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "ai_ec2" {
  name               = "${local.name_prefix}-ec2-role"
  assume_role_policy = data.aws_iam_policy_document.ai_ec2_assume_role.json

  tags = {
    Name = "${local.name_prefix}-ec2-role"
  }
}

data "aws_iam_policy_document" "ai_ssm_parameter" {
  statement {
    sid     = "ReadTailscaleAuthKey"
    effect  = "Allow"
    actions = ["ssm:GetParameter"]
    resources = [
      "arn:${data.aws_partition.current.partition}:ssm:${var.aws_region}:${data.aws_caller_identity.current.account_id}:parameter${var.tailscale_auth_parameter_name}"
    ]
  }
}

resource "aws_iam_policy" "ai_ssm_parameter" {
  name   = "${local.name_prefix}-ssm-parameter"
  policy = data.aws_iam_policy_document.ai_ssm_parameter.json

  tags = {
    Name = "${local.name_prefix}-ssm-parameter"
  }
}

resource "aws_iam_role_policy_attachment" "ai_ssm_parameter" {
  role       = aws_iam_role.ai_ec2.name
  policy_arn = aws_iam_policy.ai_ssm_parameter.arn
}

resource "aws_iam_role_policy_attachment" "ai_ssm_managed_instance" {
  role       = aws_iam_role.ai_ec2.name
  policy_arn = "arn:${data.aws_partition.current.partition}:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_role_policy_attachment" "ai_sqs" {
  role       = aws_iam_role.ai_ec2.name
  policy_arn = data.terraform_remote_state.messaging.outputs.ai_sqs_policy_arn
}

resource "aws_iam_instance_profile" "ai_ec2" {
  name = "${local.name_prefix}-instance-profile"
  role = aws_iam_role.ai_ec2.name

  tags = {
    Name = "${local.name_prefix}-instance-profile"
  }
}
