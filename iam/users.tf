locals {
  # Existing console-created users. Login profiles, access keys, and MFA devices
  # intentionally remain outside Terraform so importing does not rotate or alter
  # credentials.
  users = {
    eric = {
      tags = {
        Project = "StockSpoon"
        Role    = "AI"
      }
    }
    ezra = {
      tags = {
        Project = "StockSpoon"
        Role    = "AI"
      }
    }
    lily = {
      tags = {}
    }
    pattie = {
      tags = {}
    }
    pattie_for_terraform = {
      tags = {}
    }
    river = {
      tags = {
        Project = "StockSpoon"
        Role    = "Backend"
      }
    }
    stella = {
      tags = {}
    }
    stella_for_terraform = {
      tags = {}
    }
  }

  user_group_memberships = {
    eric                 = "stockspoon_developer"
    ezra                 = "stockspoon_developer"
    lily                 = "stockspoon_developer"
    pattie               = "cloud_developer"
    pattie_for_terraform = "terraform"
    river                = "stockspoon_developer"
    stella               = "cloud_developer"
    stella_for_terraform = "terraform"
  }

  password_policy_users = toset([
    "eric",
    "lily",
    "pattie_for_terraform",
    "river",
    "stella",
    "stella_for_terraform",
  ])
}

resource "aws_iam_user" "existing" {
  for_each = local.users

  name          = each.key
  path          = "/"
  force_destroy = false
  tags          = each.value.tags

  lifecycle {
    prevent_destroy = true
  }
}

resource "aws_iam_user_group_membership" "existing" {
  for_each = local.user_group_memberships

  user   = aws_iam_user.existing[each.key].name
  groups = [aws_iam_group.existing[each.value].name]
}

resource "aws_iam_user_policy_attachment" "change_password" {
  for_each = local.password_policy_users

  user       = aws_iam_user.existing[each.value].name
  policy_arn = "arn:aws:iam::aws:policy/IAMUserChangePassword"
}
