data "aws_iam_policy_document" "terraform_ci_write_compute" {
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
