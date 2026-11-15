data "aws_iam_policy_document" "terraform_ci_write_compute" {
  dynamic "statement" {
    for_each = var.fis_resource_arns == null ? [] : [var.fis_resource_arns]
    content {
      sid    = "ManageFisTemplatesOnly"
      effect = "Allow"
      actions = [
        "fis:CreateExperimentTemplate", "fis:UpdateExperimentTemplate",
        "fis:DeleteExperimentTemplate", "fis:TagResource", "fis:UntagResource",
      ]
      resources = [statement.value.templates, statement.value.actions]
    }
  }

  dynamic "statement" {
    for_each = var.fis_resource_arns == null ? [] : [var.fis_resource_arns]
    content {
      sid       = "PassExperimentRolesToFis"
      effect    = "Allow"
      actions   = ["iam:PassRole"]
      resources = statement.value.roles
      condition {
        test     = "StringEquals"
        variable = "iam:PassedToService"
        values   = ["fis.amazonaws.com"]
      }
    }
  }

  statement {
    sid    = "ManageEc2AndElastiCacheInSeoul"
    effect = "Allow"
    actions = [
      "ec2:*",
      "elasticache:*",
    ]
    resources = ["*"]

    condition {
      test     = "StringEquals"
      variable = "aws:RequestedRegion"
      values   = ["ap-northeast-2"]
    }
  }

  statement {
    sid    = "ManageAlbAndCertificatesInSeoul"
    effect = "Allow"
    actions = [
      "acm:AddTagsToCertificate",
      "acm:DeleteCertificate",
      "acm:RemoveTagsFromCertificate",
      "acm:RequestCertificate",
      "acm:UpdateCertificateOptions",
      "elasticloadbalancing:*",
    ]
    resources = ["*"]

    condition {
      test     = "StringEquals"
      variable = "aws:RequestedRegion"
      values   = ["ap-northeast-2"]
    }
  }

  statement {
    sid    = "ManageEcsAndAutoScalingInSeoul"
    effect = "Allow"
    actions = [
      "autoscaling:*",
      "ecs:*",
    ]
    resources = ["*"]

    condition {
      test     = "StringEquals"
      variable = "aws:RequestedRegion"
      values   = ["ap-northeast-2"]
    }
  }

  statement {
    sid    = "ManageCloudMapInSeoul"
    effect = "Allow"
    actions = [
      "servicediscovery:CreatePrivateDnsNamespace",
      "servicediscovery:DeleteNamespace",
      "servicediscovery:GetNamespace",
      "servicediscovery:ListNamespaces",
      "servicediscovery:ListOperations",
      "servicediscovery:GetOperation",
      "servicediscovery:CreateService",
      "servicediscovery:DeleteService",
      "servicediscovery:GetService",
      "servicediscovery:ListServices",
      "servicediscovery:UpdateService",
      "servicediscovery:TagResource",
      "servicediscovery:UntagResource",
      "servicediscovery:ListTagsForResource",
    ]
    resources = ["*"]

    condition {
      test     = "StringEquals"
      variable = "aws:RequestedRegion"
      values   = ["ap-northeast-2"]
    }
  }

  # CreateFileSystem does not support resource-level scoping, so require the
  # Repman state tag, encryption, and the Seoul region at creation time.
  statement {
    sid       = "CreateRepmanEfsFileSystemInSeoul"
    effect    = "Allow"
    actions   = ["elasticfilesystem:CreateFileSystem"]
    resources = ["*"]

    condition {
      test     = "StringEquals"
      variable = "aws:RequestTag/Name"
      values   = [var.resource_arns.efs_repman_state_name]
    }

    condition {
      test     = "Bool"
      variable = "elasticfilesystem:Encrypted"
      values   = ["true"]
    }

    condition {
      test     = "StringEquals"
      variable = "aws:RequestedRegion"
      values   = ["ap-northeast-2"]
    }
  }

  # EFS performs a separate TagResource authorization for tagged creation.
  statement {
    sid       = "TagRepmanEfsFileSystemOnCreateInSeoul"
    effect    = "Allow"
    actions   = ["elasticfilesystem:TagResource"]
    resources = var.resource_arns.efs_file_systems

    condition {
      test     = "StringEquals"
      variable = "elasticfilesystem:CreateAction"
      values   = ["CreateFileSystem"]
    }

    condition {
      test     = "StringEquals"
      variable = "aws:RequestTag/Name"
      values   = [var.resource_arns.efs_repman_state_name]
    }

    condition {
      test     = "StringEquals"
      variable = "aws:RequestedRegion"
      values   = ["ap-northeast-2"]
    }
  }

  statement {
    sid       = "TagRepmanEfsAccessPointOnCreateInSeoul"
    effect    = "Allow"
    actions   = ["elasticfilesystem:TagResource"]
    resources = var.resource_arns.efs_access_points

    condition {
      test     = "StringEquals"
      variable = "elasticfilesystem:CreateAction"
      values   = ["CreateAccessPoint"]
    }

    condition {
      test     = "StringEquals"
      variable = "aws:RequestTag/Name"
      values   = [var.resource_arns.efs_repman_state_name]
    }

    condition {
      test     = "StringEquals"
      variable = "aws:RequestedRegion"
      values   = ["ap-northeast-2"]
    }
  }

  # Repman creates its access point only on the tagged Repman file system.
  statement {
    sid       = "CreateRepmanEfsAccessPointInSeoul"
    effect    = "Allow"
    actions   = ["elasticfilesystem:CreateAccessPoint"]
    resources = var.resource_arns.efs_file_systems

    condition {
      test     = "StringEquals"
      variable = "aws:RequestTag/Name"
      values   = [var.resource_arns.efs_repman_state_name]
    }

    condition {
      test     = "StringEquals"
      variable = "aws:ResourceTag/Name"
      values   = [var.resource_arns.efs_repman_state_name]
    }

    condition {
      test     = "StringEquals"
      variable = "aws:RequestedRegion"
      values   = ["ap-northeast-2"]
    }
  }

  # EFS provider refreshes and manages only the Repman-tagged file system.
  statement {
    sid    = "ManageRepmanEfsFileSystemInSeoul"
    effect = "Allow"
    actions = [
      "elasticfilesystem:CreateMountTarget",
      "elasticfilesystem:DeleteFileSystem",
      "elasticfilesystem:DeleteMountTarget",
      "elasticfilesystem:DescribeAccessPoints",
      "elasticfilesystem:DescribeFileSystems",
      "elasticfilesystem:DescribeLifecycleConfiguration",
      "elasticfilesystem:DescribeMountTargetSecurityGroups",
      "elasticfilesystem:DescribeMountTargets",
      "elasticfilesystem:ListTagsForResource",
      "elasticfilesystem:ModifyMountTargetSecurityGroups",
      "elasticfilesystem:UntagResource",
      "elasticfilesystem:UpdateFileSystem",
    ]
    resources = var.resource_arns.efs_file_systems

    condition {
      test     = "StringEquals"
      variable = "aws:ResourceTag/Name"
      values   = [var.resource_arns.efs_repman_state_name]
    }

    condition {
      test     = "StringEquals"
      variable = "aws:RequestedRegion"
      values   = ["ap-northeast-2"]
    }
  }

  # Access-point lifecycle operations are separately scoped to the same Name tag.
  statement {
    sid    = "ManageRepmanEfsAccessPointInSeoul"
    effect = "Allow"
    actions = [
      "elasticfilesystem:DeleteAccessPoint",
      "elasticfilesystem:DescribeAccessPoints",
      "elasticfilesystem:DescribeMountTargets",
      "elasticfilesystem:ListTagsForResource",
      "elasticfilesystem:UntagResource",
    ]
    resources = var.resource_arns.efs_access_points

    condition {
      test     = "StringEquals"
      variable = "aws:ResourceTag/Name"
      values   = [var.resource_arns.efs_repman_state_name]
    }

    condition {
      test     = "StringEquals"
      variable = "aws:RequestedRegion"
      values   = ["ap-northeast-2"]
    }
  }

  # Cloud Map creates the Route 53 private hosted zone for a private namespace.
  # Route 53 is a global service, so these actions cannot use RequestedRegion.
  statement {
    sid    = "CreateCloudMapPrivateHostedZone"
    effect = "Allow"
    actions = [
      "route53:CreateHostedZone",
      "route53:GetHostedZone",
      "route53:ListHostedZonesByName",
    ]
    resources = ["*"]
  }

  statement {
    sid    = "ManageEcsServiceAutoScalingInSeoul"
    effect = "Allow"
    actions = [
      "application-autoscaling:RegisterScalableTarget",
      "application-autoscaling:DeregisterScalableTarget",
      "application-autoscaling:PutScalingPolicy",
      "application-autoscaling:DeleteScalingPolicy",
      "application-autoscaling:PutScheduledAction",
      "application-autoscaling:DeleteScheduledAction",
      "application-autoscaling:TagResource",
      "application-autoscaling:UntagResource",
    ]
    resources = ["*"]

    condition {
      test     = "StringEquals"
      variable = "aws:RequestedRegion"
      values   = ["ap-northeast-2"]
    }
  }
}
