locals {
  db_write_replay_consumer_name            = "${local.name_prefix}-db-write-replay-forwarder"
  db_write_replay_proxy_host               = "${var.proxysql_dns_service_name}.${var.proxysql_dns_namespace}"
  db_write_replay_mysql_user_parameter     = "/${var.project_name}/v2/${var.environment}/backend/MYSQL_USER"
  db_write_replay_mysql_password_parameter = "/${var.project_name}/v2/${var.environment}/backend/MYSQL_PASSWORD"
}

data "aws_iam_policy_document" "db_write_replay_forwarder_assume_role" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["lambda.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "db_write_replay_forwarder" {
  name               = "${local.db_write_replay_consumer_name}-role"
  assume_role_policy = data.aws_iam_policy_document.db_write_replay_forwarder_assume_role.json

  tags = {
    Name = "${local.db_write_replay_consumer_name}-role"
  }
}

resource "aws_cloudwatch_log_group" "db_write_replay_forwarder" {
  name              = "/aws/lambda/${local.db_write_replay_consumer_name}"
  retention_in_days = 14

  tags = {
    Name = "${local.db_write_replay_consumer_name}-logs"
  }
}

data "aws_iam_policy_document" "db_write_replay_forwarder" {
  statement {
    sid     = "ReadProxySqlCredentials"
    effect  = "Allow"
    actions = ["ssm:GetParameter"]
    resources = [
      "arn:${data.aws_partition.messaging.partition}:ssm:${var.aws_region}:${data.aws_caller_identity.messaging.account_id}:parameter${local.db_write_replay_mysql_user_parameter}",
      "arn:${data.aws_partition.messaging.partition}:ssm:${var.aws_region}:${data.aws_caller_identity.messaging.account_id}:parameter${local.db_write_replay_mysql_password_parameter}",
    ]
  }

  statement {
    sid       = "DecryptProxySqlCredentials"
    effect    = "Allow"
    actions   = ["kms:Decrypt"]
    resources = [data.aws_kms_alias.ssm.target_key_arn]
  }

  statement {
    sid    = "CreateAndManageLambdaVpcNetworkInterfaces"
    effect = "Allow"
    actions = [
      "ec2:CreateNetworkInterface",
      "ec2:DescribeNetworkInterfaces",
      "ec2:DescribeSubnets",
      "ec2:DeleteNetworkInterface",
      "ec2:AssignPrivateIpAddresses",
      "ec2:UnassignPrivateIpAddresses",
    ]
    resources = ["*"]
  }

  statement {
    sid    = "WriteForwarderLogs"
    effect = "Allow"
    actions = [
      "logs:CreateLogStream",
      "logs:PutLogEvents",
    ]
    resources = ["${aws_cloudwatch_log_group.db_write_replay_forwarder.arn}:*"]
  }
}

resource "aws_iam_role_policy" "db_write_replay_forwarder" {
  name   = "${local.db_write_replay_consumer_name}-policy"
  role   = aws_iam_role.db_write_replay_forwarder.id
  policy = data.aws_iam_policy_document.db_write_replay_forwarder.json
}

resource "aws_iam_role_policy_attachment" "db_write_replay_forwarder_sqs" {
  role       = aws_iam_role.db_write_replay_forwarder.name
  policy_arn = aws_iam_policy.db_write_replay_consumer.arn
}

data "archive_file" "db_write_replay_forwarder" {
  type        = "zip"
  source_dir  = "${path.module}/.terraform/db_write_replay_build"
  output_path = "${path.module}/.terraform/db_write_replay_forwarder.zip"
}

resource "aws_lambda_function" "db_write_replay_forwarder" {
  function_name    = local.db_write_replay_consumer_name
  description      = "Manually drains FIFO DB write replay messages through ProxySQL"
  role             = aws_iam_role.db_write_replay_forwarder.arn
  runtime          = "python3.12"
  handler          = "db_write_replay_forwarder.handler"
  filename         = data.archive_file.db_write_replay_forwarder.output_path
  source_code_hash = data.archive_file.db_write_replay_forwarder.output_base64sha256
  timeout          = 900
  memory_size      = 512

  vpc_config {
    subnet_ids         = data.terraform_remote_state.shared.outputs.private_subnet_ids
    security_group_ids = [aws_security_group.db_write_replay_forwarder.id]
  }

  environment {
    variables = {
      DB_WRITE_REPLAY_QUEUE_URL                = aws_sqs_queue.db_write_replay.url
      DB_WRITE_REPLAY_PROXYSQL_HOST            = local.db_write_replay_proxy_host
      DB_WRITE_REPLAY_PROXYSQL_PORT            = tostring(var.proxysql_port)
      DB_WRITE_REPLAY_DATABASE                 = var.db_write_replay_database
      DB_WRITE_REPLAY_MYSQL_USER_PARAMETER     = local.db_write_replay_mysql_user_parameter
      DB_WRITE_REPLAY_MYSQL_PASSWORD_PARAMETER = local.db_write_replay_mysql_password_parameter
    }
  }

  depends_on = [
    aws_iam_role_policy.db_write_replay_forwarder,
    aws_iam_role_policy_attachment.db_write_replay_forwarder_sqs,
    aws_cloudwatch_log_group.db_write_replay_forwarder,
    aws_vpc_security_group_egress_rule.db_write_replay_to_proxysql,
    aws_vpc_security_group_egress_rule.db_write_replay_https,
  ]

  tags = {
    Name = local.db_write_replay_consumer_name
  }
}

resource "aws_security_group" "db_write_replay_forwarder" {
  name        = "${local.db_write_replay_consumer_name}-sg"
  description = "Allows the manually invoked DB write replay Lambda to reach ProxySQL"
  vpc_id      = data.terraform_remote_state.shared.outputs.vpc_id

  tags = {
    Name = "${local.db_write_replay_consumer_name}-sg"
  }
}

resource "aws_vpc_security_group_egress_rule" "db_write_replay_to_proxysql" {
  security_group_id = aws_security_group.db_write_replay_forwarder.id
  cidr_ipv4         = data.terraform_remote_state.shared.outputs.vpc_cidr_block
  from_port         = var.proxysql_port
  to_port           = var.proxysql_port
  ip_protocol       = "tcp"
  description       = "Allow the replay Lambda to reach the ProxySQL client port in the VPC"
}

resource "aws_vpc_security_group_egress_rule" "db_write_replay_https" {
  security_group_id = aws_security_group.db_write_replay_forwarder.id
  cidr_ipv4         = "0.0.0.0/0"
  from_port         = 443
  to_port           = 443
  ip_protocol       = "tcp"
  description       = "Allow the replay Lambda to call SQS, SSM, and CloudWatch APIs through NAT"
}
