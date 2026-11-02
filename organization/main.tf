# The organization and its three accounts. The organization, the management
# account and the Offers Platform account are imported (README "Setup"); only
# the ABC Bank account is created here.

data "aws_caller_identity" "management" {}

resource "aws_organizations_organization" "this" {
  feature_set = "ALL"

  # CloudTrail trusted access for FND-4's organization trail; sso for Identity
  # Center. FND-4 adds any further service principals here.
  aws_service_access_principals = [
    "cloudtrail.amazonaws.com",
    "sso.amazonaws.com",
  ]

  # AWS attaches its default FullAWSAccess SCP, so nothing is restricted.
  # No custom SCPs (out of scope).
  enabled_policy_types = ["SERVICE_CONTROL_POLICY"]

  lifecycle {
    prevent_destroy = true
  }
}

# Imported for its cost tags only (design D5). Every other attribute is
# ignored. Never removed by destroy: to take it out of state use
# `terraform state rm` or a `removed` block with `destroy = false`.
resource "aws_organizations_account" "management" {
  name              = var.management_account_name
  email             = var.management_account_email
  close_on_deletion = false

  lifecycle {
    prevent_destroy = true
    ignore_changes  = [name, email, role_name, iam_user_access_to_billing]

    postcondition {
      condition     = self.id == aws_organizations_organization.this.master_account_id
      error_message = "aws_organizations_account.management must be the organization's management account."
    }
  }
}

resource "aws_organizations_account" "abc_bank" {
  name                       = var.abc_bank_account_name
  email                      = var.abc_bank_account_email
  role_name                  = "OrganizationAccountAccessRole"
  iam_user_access_to_billing = "ALLOW" # so IAM roles can read Cost Explorer
  close_on_deletion          = false

  lifecycle {
    prevent_destroy = true
    ignore_changes  = [role_name, iam_user_access_to_billing]
  }
}

# Imported after the account accepts the invitation (README "Setup", step 5).
# Tags only; every other attribute is ignored.
resource "aws_organizations_account" "offers_platform" {
  name              = var.offers_platform_account_name
  email             = var.offers_platform_account_email
  close_on_deletion = false

  lifecycle {
    prevent_destroy = true
    ignore_changes  = [name, email, role_name, iam_user_access_to_billing]
  }
}
