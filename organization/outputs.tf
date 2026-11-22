output "organization_id" {
  description = "ID of the AWS Organization (o-...)."
  value       = aws_organizations_organization.this.id
}

output "management_account_id" {
  description = "Account ID of the Management + Shared Services account (the organization's management account)."
  value       = aws_organizations_account.management.id
}

output "abc_bank_account_id" {
  description = "Account ID of the ABC Bank member account."
  value       = aws_organizations_account.abc_bank.id
}

output "offers_platform_account_id" {
  description = "Account ID of the Offers Platform member account."
  value       = aws_organizations_account.offers_platform.id
}

output "identity_store_id" {
  description = "ID of the Identity Center identity store."
  value       = local.identity_store_id
}

output "sso_instance_arn" {
  description = "ARN of the IAM Identity Center instance (us-east-1)."
  value       = local.sso_instance_arn
}

output "permission_set_arns" {
  description = "Permission set ARNs by permission set name."
  value = {
    (aws_ssoadmin_permission_set.administrator.name)               = aws_ssoadmin_permission_set.administrator.arn
    (aws_ssoadmin_permission_set.abc_bank_engineering.name)        = aws_ssoadmin_permission_set.abc_bank_engineering.arn
    (aws_ssoadmin_permission_set.offers_platform_engineering.name) = aws_ssoadmin_permission_set.offers_platform_engineering.arn
  }
}

output "boundary_policy_arns" {
  description = "Permissions boundary policy ARNs by member account (abc_bank, offers_platform)."
  value = {
    abc_bank        = aws_iam_policy.boundary_abc_bank.arn
    offers_platform = aws_iam_policy.boundary_offers_platform.arn
  }
}

output "offers_platform_oaar_arn" {
  description = "ARN of OrganizationAccountAccessRole in the Offers Platform account (recovery path)."
  value       = aws_iam_role.offers_platform_oaar.arn
}
