data "aws_caller_identity" "current" {}

data "aws_partition" "current" {}

data "aws_organizations_organization" "current" {}

locals {
  management_account_id = data.aws_caller_identity.current.account_id
  organization_id       = data.aws_organizations_organization.current.id
  partition             = data.aws_partition.current.partition

  # Effective budget limit: the AC3 override when set, otherwise the posture's limit.
  budget_limit = coalesce(var.budget_limit_override_usd, var.budget_limits_usd[var.posture])
}
