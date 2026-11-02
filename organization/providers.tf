# Management account. Credentials come from AWS_PROFILE (fnd-management-admin).
provider "aws" {
  region = "us-east-1"

  default_tags {
    tags = var.cost_tags
  }
}

# ABC Bank account, through its Identity Center Administrator profile (design
# decision D2). Every resource that uses this alias checks, with a
# precondition, that the profile really points at the ABC Bank account.
provider "aws" {
  alias   = "abc_bank"
  region  = "us-east-1"
  profile = var.abc_bank_admin_profile

  default_tags {
    tags = var.cost_tags
  }
}

# Offers Platform account, through its Identity Center Administrator profile.
# Same precondition check as above.
provider "aws" {
  alias   = "offers_platform"
  region  = "us-east-1"
  profile = var.offers_platform_admin_profile

  default_tags {
    tags = var.cost_tags
  }
}
