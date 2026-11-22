# Personal values (account emails, the engineer's name and email) go in the
# untracked terraform.tfvars; example.tfvars shows the shape.

variable "management_account_name" {
  description = "Name of the management account as it is today (used only so the import matches; changes are ignored)."
  type        = string
  sensitive   = true
}

variable "management_account_email" {
  description = "Root email of the management account as it is today (used only so the import matches; changes are ignored)."
  type        = string
  sensitive   = true
}

variable "abc_bank_account_name" {
  description = "Name of the ABC Bank member account created in the organization."
  type        = string
  default     = "ABC Bank"
  sensitive   = true
}

variable "abc_bank_account_email" {
  description = "Root email for the new ABC Bank account. Must not belong to any other AWS account."
  type        = string
  sensitive   = true
}

variable "offers_platform_account_name" {
  description = "Name of the existing Offers Platform account (for the README and so the import matches; changes are ignored)."
  type        = string
  default     = "Offers Platform"
  sensitive   = true
}

variable "offers_platform_account_email" {
  description = "Root email of the existing Offers Platform account. Required by aws_organizations_account so the import matches; changes are ignored."
  type        = string
  sensitive   = true
}

variable "engineer_user_name" {
  description = "Identity Center user name of the engineer (as created by hand in README Setup step 1)."
  type        = string
  sensitive   = true
}

variable "engineer_given_name" {
  description = "Given name of the engineer's Identity Center user."
  type        = string
  sensitive   = true
}

variable "engineer_family_name" {
  description = "Family name of the engineer's Identity Center user."
  type        = string
  sensitive   = true
}

variable "engineer_email" {
  description = "Primary email of the engineer's Identity Center user."
  type        = string
  sensitive   = true
}

variable "abc_bank_admin_profile" {
  description = "AWS CLI profile (Identity Center Administrator in the ABC Bank account) used by the aws.abc_bank provider."
  type        = string
  default     = "fnd-abc-bank-admin"
}

variable "offers_platform_admin_profile" {
  description = "AWS CLI profile (Identity Center Administrator in the Offers Platform account) used by the aws.offers_platform provider."
  type        = string
  default     = "fnd-offers-platform-admin"
}

variable "boundary_policy_name" {
  description = "Name of the permissions boundary policy created in each member account (path /)."
  type        = string
  default     = "EngineeringPermissionsBoundary"
}

variable "engineering_role_path" {
  description = "IAM path that marks a role or instance profile as bounded. Engineering roles may only create and change roles under this path."
  type        = string
  default     = "/eng/"

  validation {
    condition     = can(regex("^/[A-Za-z0-9_+=,.@-]+/$", var.engineering_role_path))
    error_message = "engineering_role_path must start and end with / and contain one path segment, for example /eng/."
  }
}

variable "abc_bank_kms_key_alias" {
  description = "Alias name (without alias/) of the ABC Bank KMS key that ABC-4 creates. The ABC Bank engineering role may use it; boundaries deny direct use."
  type        = string
  default     = "abc-bank-kms-key"
}

variable "abc_bank_state_bucket" {
  description = "Name of the ABC Bank Terraform state bucket that ABC-3 creates. The ABC Bank engineering role may read and write it."
  type        = string
  default     = "abc-bank-offers-platform"
}

variable "cost_tags" {
  description = "The four cost-allocation tags applied to every taggable resource through each provider's default_tags (values from AGENTS.md)."
  type        = map(string)
  default = {
    data-product = "aws-foundations"
    environment  = "shared"
    owner        = "Lakshmi100"
    cost-center  = "offers-platform-portfolio"
  }
}
