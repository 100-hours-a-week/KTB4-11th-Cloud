import {
  for_each = local.users

  to = aws_iam_user.existing[each.key]
  id = each.key
}

import {
  for_each = local.groups

  to = aws_iam_group.existing[each.value]
  id = each.value
}

import {
  for_each = local.user_group_memberships

  to = aws_iam_user_group_membership.existing[each.key]
  id = "${each.key}/${each.value}"
}

import {
  for_each = local.password_policy_users

  to = aws_iam_user_policy_attachment.change_password[each.value]
  id = "${each.value}/arn:aws:iam::aws:policy/IAMUserChangePassword"
}

import {
  for_each = local.group_policy_attachments

  to = aws_iam_group_policy_attachment.existing[each.key]
  id = "${each.value.group}/${each.value.policy_arn}"
}

import {
  to = aws_iam_group_policy.terraform_ci_permission_editor
  id = "terraform:stockspoon-v1-terraform-ci-permission-editor"
}
