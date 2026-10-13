# AI 레포 cd-ecs-v2.yaml이 market-http·market-streamer를 배포할 때 assume하는 Role
# Task Definition 새 리비전 등록과 서비스 갱신만 허용한다. (인프라 변경은 Terraform CI가 담당)

locals {
  ecs_deploy_service_arns = [
    for name in ["market-http", "market-streamer"] :
    "arn:${local.partition}:ecs:${var.aws_region}:${local.account_id}:service/${aws_ecs_cluster.main.name}/${var.name_prefix}-${name}"
  ]
}

data "aws_iam_policy_document" "github_actions_ecs_deploy_assume_role" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = [data.terraform_remote_state.app.outputs.github_actions_oidc_provider_arn]
    }

    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:aud"
      values   = ["sts.amazonaws.com"]
    }

    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:sub"
      values   = var.ecs_deploy_github_subjects
    }
  }
}

resource "aws_iam_role" "github_actions_ecs_deploy" {
  name               = "${var.name_prefix}-github-actions-ecs-deploy"
  description        = "Role assumed by the AI repository CD to deploy market services to ECS"
  assume_role_policy = data.aws_iam_policy_document.github_actions_ecs_deploy_assume_role.json
}

data "aws_iam_policy_document" "github_actions_ecs_deploy" {
  # Task Definition은 리소스 수준 권한을 지원하지 않는다.
  statement {
    sid    = "RegisterTaskDefinitions"
    effect = "Allow"
    actions = [
      "ecs:DescribeTaskDefinition",
      "ecs:RegisterTaskDefinition",
    ]
    resources = ["*"]
  }

  statement {
    sid    = "DeployMarketServices"
    effect = "Allow"
    actions = [
      "ecs:DescribeServices",
      "ecs:UpdateService",
    ]
    resources = local.ecs_deploy_service_arns
  }

  # 새 리비전에 기존 Task Execution Role·Task Role을 그대로 지정하기 위해 필요하다.
  statement {
    sid     = "PassMarketTaskRoles"
    effect  = "Allow"
    actions = ["iam:PassRole"]
    resources = [
      aws_iam_role.ecs_task_execution.arn,
      aws_iam_role.market_http_task.arn,
      aws_iam_role.market_streamer_task.arn,
    ]

    condition {
      test     = "StringEquals"
      variable = "iam:PassedToService"
      values   = ["ecs-tasks.amazonaws.com"]
    }
  }
}

resource "aws_iam_role_policy" "github_actions_ecs_deploy" {
  name   = "${var.name_prefix}-github-actions-ecs-deploy"
  role   = aws_iam_role.github_actions_ecs_deploy.id
  policy = data.aws_iam_policy_document.github_actions_ecs_deploy.json
}
