# IAM Identity Center: the engineer, three permission sets and five account
# assignments. The instance, the user, the Administrator permission set, its
# AdministratorAccess attachment and its management-account assignment are
# created by hand and imported (README "Setup", steps 1 and 3).

data "aws_ssoadmin_instances" "this" {}

locals {
  sso_instance_arn  = tolist(data.aws_ssoadmin_instances.this.arns)[0]
  identity_store_id = tolist(data.aws_ssoadmin_instances.this.identity_store_ids)[0]
}

# Identity Store users cannot be tagged.
resource "aws_identitystore_user" "engineer" {
  identity_store_id = local.identity_store_id

  user_name    = var.engineer_user_name
  display_name = "${var.engineer_given_name} ${var.engineer_family_name}"

  name {
    given_name  = var.engineer_given_name
    family_name = var.engineer_family_name
  }

  emails {
    value   = var.engineer_email
    primary = true
  }
}

resource "aws_ssoadmin_permission_set" "administrator" {
  name             = "Administrator"
  description      = "Setup, recovery and long-lived foundations. Not for day-to-day work."
  instance_arn     = local.sso_instance_arn
  session_duration = "PT1H"

  lifecycle {
    prevent_destroy = true
  }
}

resource "aws_ssoadmin_managed_policy_attachment" "administrator" {
  instance_arn       = local.sso_instance_arn
  permission_set_arn = aws_ssoadmin_permission_set.administrator.arn
  managed_policy_arn = "arn:aws:iam::aws:policy/AdministratorAccess"
}

resource "aws_ssoadmin_permission_set" "abc_bank_engineering" {
  name             = "ABCBankEngineering"
  description      = "Day-to-day ABC Bank session work (ABC-6 on). Roles it creates live under /eng/ and carry EngineeringPermissionsBoundary."
  instance_arn     = local.sso_instance_arn
  session_duration = "PT4H"
}

resource "aws_ssoadmin_permission_set_inline_policy" "abc_bank_engineering" {
  instance_arn       = local.sso_instance_arn
  permission_set_arn = aws_ssoadmin_permission_set.abc_bank_engineering.arn
  inline_policy      = data.aws_iam_policy_document.abc_bank_engineering.json
}

resource "aws_ssoadmin_permission_set" "offers_platform_engineering" {
  name             = "OffersPlatformEngineering"
  description      = "Day-to-day new work in Offers Platform (PowerUserAccess-based). Roles it creates live under /eng/ and carry EngineeringPermissionsBoundary."
  instance_arn     = local.sso_instance_arn
  session_duration = "PT4H"
}

resource "aws_ssoadmin_permission_set_inline_policy" "offers_platform_engineering" {
  instance_arn       = local.sso_instance_arn
  permission_set_arn = aws_ssoadmin_permission_set.offers_platform_engineering.arn
  inline_policy      = data.aws_iam_policy_document.offers_platform_engineering.json
}

# Administrator in all three accounts. prevent_destroy covers every key, so
# no administrator assignment can be removed by accident (AGENTS.md: never
# remove the last administrator assignment).
resource "aws_ssoadmin_account_assignment" "administrator" {
  for_each = {
    management      = aws_organizations_account.management.id
    abc_bank        = aws_organizations_account.abc_bank.id
    offers_platform = aws_organizations_account.offers_platform.id
  }

  instance_arn       = local.sso_instance_arn
  permission_set_arn = aws_ssoadmin_permission_set.administrator.arn
  principal_type     = "USER"
  principal_id       = aws_identitystore_user.engineer.user_id
  target_type        = "AWS_ACCOUNT"
  target_id          = each.value

  lifecycle {
    prevent_destroy = true
  }
}

resource "aws_ssoadmin_account_assignment" "abc_bank_engineering" {
  instance_arn       = local.sso_instance_arn
  permission_set_arn = aws_ssoadmin_permission_set.abc_bank_engineering.arn
  principal_type     = "USER"
  principal_id       = aws_identitystore_user.engineer.user_id
  target_type        = "AWS_ACCOUNT"
  target_id          = aws_organizations_account.abc_bank.id
}

resource "aws_ssoadmin_account_assignment" "offers_platform_engineering" {
  instance_arn       = local.sso_instance_arn
  permission_set_arn = aws_ssoadmin_permission_set.offers_platform_engineering.arn
  principal_type     = "USER"
  principal_id       = aws_identitystore_user.engineer.user_id
  target_type        = "AWS_ACCOUNT"
  target_id          = aws_organizations_account.offers_platform.id
}
