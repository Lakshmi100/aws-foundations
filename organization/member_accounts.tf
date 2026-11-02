# Resources inside the member accounts, through the Identity Center
# Administrator profiles (design decision D2). Each resource checks that its
# provider alias really points at the matching account, so a profile set to
# the wrong account fails the plan instead of writing to that account.

data "aws_caller_identity" "abc_bank" {
  provider = aws.abc_bank
}

data "aws_caller_identity" "offers_platform" {
  provider = aws.offers_platform
}

# ------------------------------------------------------------------ ABC Bank

resource "aws_iam_policy" "boundary_abc_bank" {
  provider = aws.abc_bank

  name        = var.boundary_policy_name
  path        = "/"
  description = "Permissions boundary for roles created by ABCBankEngineering: capped to that role's permissions (FND-3)."
  policy      = data.aws_iam_policy_document.abc_bank_boundary.json

  lifecycle {
    precondition {
      condition     = data.aws_caller_identity.abc_bank.account_id == aws_organizations_account.abc_bank.id
      error_message = "The aws.abc_bank provider profile (var.abc_bank_admin_profile) does not point at the ABC Bank account."
    }
  }
}

# ----------------------------------------------------------- Offers Platform

resource "aws_iam_policy" "boundary_offers_platform" {
  provider = aws.offers_platform

  name        = var.boundary_policy_name
  path        = "/"
  description = "Permissions boundary for roles created by OffersPlatformEngineering: capped to that role's permissions (FND-3)."
  policy      = data.aws_iam_policy_document.offers_platform_boundary.json

  lifecycle {
    precondition {
      condition     = data.aws_caller_identity.offers_platform.account_id == aws_organizations_account.offers_platform.id
      error_message = "The aws.offers_platform provider profile (var.offers_platform_admin_profile) does not point at the Offers Platform account."
    }
  }
}

# AWS creates OrganizationAccountAccessRole only in accounts created inside
# the organization; the invited Offers Platform account gets it here. It is
# the member-account recovery path (README "Recovery").
data "aws_iam_policy_document" "offers_platform_oaar_trust" {
  statement {
    sid     = "ManagementAccountOnly"
    effect  = "Allow"
    actions = ["sts:AssumeRole"]

    principals {
      type        = "AWS"
      identifiers = ["arn:aws:iam::${data.aws_caller_identity.management.account_id}:root"]
    }
  }
}

resource "aws_iam_role" "offers_platform_oaar" {
  provider = aws.offers_platform

  name                 = "OrganizationAccountAccessRole"
  path                 = "/"
  description          = "Recovery access from the management account (FND-3)."
  assume_role_policy   = data.aws_iam_policy_document.offers_platform_oaar_trust.json
  max_session_duration = 3600

  lifecycle {
    precondition {
      condition     = data.aws_caller_identity.offers_platform.account_id == aws_organizations_account.offers_platform.id
      error_message = "The aws.offers_platform provider profile (var.offers_platform_admin_profile) does not point at the Offers Platform account."
    }
  }
}

resource "aws_iam_role_policy_attachment" "offers_platform_oaar_admin" {
  provider = aws.offers_platform

  role       = aws_iam_role.offers_platform_oaar.name
  policy_arn = "arn:aws:iam::aws:policy/AdministratorAccess"

  lifecycle {
    precondition {
      condition     = data.aws_caller_identity.offers_platform.account_id == aws_organizations_account.offers_platform.id
      error_message = "The aws.offers_platform provider profile (var.offers_platform_admin_profile) does not point at the Offers Platform account."
    }
  }
}
