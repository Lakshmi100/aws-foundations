# Engineering role policies and permissions boundaries (design section 3.4).
#
# Each boundary is its engineering role's own document plus the boundary-only
# denies (K), so a bounded role can never do more than the engineering role
# that created it (requirement 5, decision D4). Shared action lists are
# locals; statements that need an account ID are written once per account,
# in separate data sources, so a targeted apply for one account never pulls
# in the other account's resources.
#
# A "bounded role" is a role under var.engineering_role_path (/eng/) that
# carries the boundary (decision D3).

locals {
  abc_bank_account_id        = aws_organizations_account.abc_bank.id
  offers_platform_account_id = aws_organizations_account.offers_platform.id

  abc_bank_boundary_arn        = "arn:aws:iam::${local.abc_bank_account_id}:policy/${var.boundary_policy_name}"
  offers_platform_boundary_arn = "arn:aws:iam::${local.offers_platform_account_id}:policy/${var.boundary_policy_name}"

  # ABC Bank also allows DMS's fixed default role names at path / (still with
  # the boundary required). Offers Platform does not: v1/v2 may own them.
  abc_bank_bounded_role_arns = [
    "arn:aws:iam::${local.abc_bank_account_id}:role${var.engineering_role_path}*",
    "arn:aws:iam::${local.abc_bank_account_id}:role/dms-vpc-role",
    "arn:aws:iam::${local.abc_bank_account_id}:role/dms-cloudwatch-logs-role",
  ]
  offers_platform_bounded_role_arns = [
    "arn:aws:iam::${local.offers_platform_account_id}:role${var.engineering_role_path}*",
  ]

  # ---- R: role management (both roles, both boundaries)

  # These support the iam:PermissionsBoundary condition key.
  bounded_role_actions = [
    "iam:CreateRole",
    "iam:AttachRolePolicy",
    "iam:DetachRolePolicy",
    "iam:PutRolePolicy",
    "iam:DeleteRolePolicy",
  ]

  # These do not support iam:PermissionsBoundary; the path scopes them.
  bounded_role_path_actions = [
    "iam:DeleteRole",
    "iam:UpdateRole",
    "iam:UpdateRoleDescription",
    "iam:UpdateAssumeRolePolicy",
    "iam:TagRole",
    "iam:UntagRole",
    "iam:PassRole",
  ]

  instance_profile_actions = [
    "iam:CreateInstanceProfile",
    "iam:DeleteInstanceProfile",
    "iam:AddRoleToInstanceProfile",
    "iam:RemoveRoleFromInstanceProfile",
    "iam:TagInstanceProfile",
    "iam:UntagInstanceProfile",
  ]

  iam_read_actions = [
    "iam:Get*",
    "iam:List*",
    "iam:GenerateCredentialReport",
    "iam:GenerateServiceLastAccessedDetails",
  ]

  # ---- G: guard denies (both roles, both boundaries)

  deny_iam_user_and_boundary_actions = [
    "iam:CreateUser",
    "iam:CreateAccessKey",
    "iam:CreateLoginProfile",
    "iam:PutRolePermissionsBoundary",
    "iam:DeleteRolePermissionsBoundary",
    "iam:PutUserPermissionsBoundary",
    "iam:DeleteUserPermissionsBoundary",
  ]

  deny_boundary_policy_edit_actions = [
    "iam:CreatePolicyVersion",
    "iam:DeletePolicy",
    "iam:DeletePolicyVersion",
    "iam:SetDefaultPolicyVersion",
    "iam:TagPolicy",
    "iam:UntagPolicy",
  ]

  deny_organization_account_identity_center_actions = concat(
    [for a in ["Accept", "Attach", "Cancel", "Close", "Create", "Decline", "Delete", "Deregister", "Detach", "Disable", "Enable", "Invite", "Leave", "Move", "Put", "Register", "Remove", "Tag", "Untag", "Update"] : "organizations:${a}*"],
    [for a in ["Accept", "Close", "Delete", "Disable", "Enable", "Put", "Start"] : "account:${a}*"],
    ["sso:*", "sso-directory:*", "identitystore:*"],
  )

  deny_billing_change_actions = concat(
    ["aws-portal:Modify*"],
    [for a in ["Create", "Delete", "Put", "Redeem", "Update"] : "billing:${a}*"],
    [for a in ["Create", "Delete", "Make", "Update"] : "payments:${a}*"],
    [for a in ["Batch", "Delete", "Put", "Update"] : "tax:${a}*"],
    [for a in ["Create", "Delete", "Put", "Update"] : "invoicing:${a}*"],
    [for a in ["Add", "Create", "Delete", "Modify", "Update"] : "purchase-orders:${a}*"],
    [for a in ["Delete", "Modify", "Put"] : "cur:${a}*"],
    [for a in ["Create", "Delete", "Update"] : "ce:${a}*"],
    ["freetier:Put*"],
  )

  # ---- A: ABC Bank engineering only

  abc_bank_ec2_write_actions = [for a in [
    "RunInstances", "StartInstances", "StopInstances", "RebootInstances", "TerminateInstances",
    "ModifyInstanceAttribute", "AssociateIamInstanceProfile", "DisassociateIamInstanceProfile",
    "ReplaceIamInstanceProfileAssociation",
    "CreateSecurityGroup", "DeleteSecurityGroup",
    "AuthorizeSecurityGroupIngress", "AuthorizeSecurityGroupEgress",
    "RevokeSecurityGroupIngress", "RevokeSecurityGroupEgress", "ModifySecurityGroupRules",
    "UpdateSecurityGroupRuleDescriptionsIngress", "UpdateSecurityGroupRuleDescriptionsEgress",
    "CreateNetworkInterface", "DeleteNetworkInterface", "ModifyNetworkInterfaceAttribute",
    "AttachNetworkInterface", "DetachNetworkInterface",
    "CreateVpcEndpoint", "ModifyVpcEndpoint", "DeleteVpcEndpoints",
    "CreateInstanceConnectEndpoint", "DeleteInstanceConnectEndpoint",
    "CreateTags", "DeleteTags",
  ] : "ec2:${a}"]

  abc_bank_access_path_actions = [
    "ssm:StartSession",
    "ssm:TerminateSession",
    "ssm:ResumeSession",
    "ssm:DescribeSessions",
    "ssm:DescribeInstanceInformation",
    "ssm:GetConnectionStatus",
    "ssm:UpdateInstanceInformation",
    "ssmmessages:*",
    "ec2messages:*",
    "ec2-instance-connect:OpenTunnel",
    "ec2-instance-connect:SendSSHPublicKey",
  ]

  abc_bank_kms_use_actions = [
    "kms:Encrypt",
    "kms:Decrypt",
    "kms:ReEncrypt*",
    "kms:GenerateDataKey*",
    "kms:DescribeKey",
  ]

  # ---- K: boundary only. Direct data-key and crypto calls on the ABC Bank
  # key are denied; calls made by AWS services on the caller's behalf carry
  # kms:ViaService and still work, as do grants.
  kms_direct_use_actions = [
    "kms:Encrypt",
    "kms:Decrypt",
    "kms:ReEncrypt*",
    "kms:GenerateDataKey*",
  ]
}

# ------------------------------------------------------------ R + G, ABC Bank

data "aws_iam_policy_document" "abc_bank_common" {
  statement {
    sid       = "BoundedRoles"
    effect    = "Allow"
    actions   = local.bounded_role_actions
    resources = local.abc_bank_bounded_role_arns

    condition {
      test     = "StringEquals"
      variable = "iam:PermissionsBoundary"
      values   = [local.abc_bank_boundary_arn]
    }
  }

  statement {
    sid       = "BoundedRolesByPath"
    effect    = "Allow"
    actions   = local.bounded_role_path_actions
    resources = local.abc_bank_bounded_role_arns
  }

  statement {
    sid       = "BoundedProfiles"
    effect    = "Allow"
    actions   = local.instance_profile_actions
    resources = ["arn:aws:iam::${local.abc_bank_account_id}:instance-profile${var.engineering_role_path}*"]
  }

  statement {
    sid       = "ServiceLinkedRoles"
    effect    = "Allow"
    actions   = ["iam:CreateServiceLinkedRole"]
    resources = ["arn:aws:iam::${local.abc_bank_account_id}:role/aws-service-role/*"]
  }

  statement {
    sid       = "IamRead"
    effect    = "Allow"
    actions   = local.iam_read_actions
    resources = ["*"]
  }

  statement {
    sid       = "DenyUsersKeysBoundaries"
    effect    = "Deny"
    actions   = local.deny_iam_user_and_boundary_actions
    resources = ["*"]
  }

  statement {
    sid       = "DenyBoundaryEdits"
    effect    = "Deny"
    actions   = local.deny_boundary_policy_edit_actions
    resources = [local.abc_bank_boundary_arn]
  }

  statement {
    sid       = "DenyOrgAccountSso"
    effect    = "Deny"
    actions   = local.deny_organization_account_identity_center_actions
    resources = ["*"]
  }

  statement {
    sid       = "DenyBilling"
    effect    = "Deny"
    actions   = local.deny_billing_change_actions
    resources = ["*"]
  }
}

# ------------------------------------------------------- R + G, Offers Platform

data "aws_iam_policy_document" "offers_platform_common" {
  statement {
    sid       = "BoundedRoles"
    effect    = "Allow"
    actions   = local.bounded_role_actions
    resources = local.offers_platform_bounded_role_arns

    condition {
      test     = "StringEquals"
      variable = "iam:PermissionsBoundary"
      values   = [local.offers_platform_boundary_arn]
    }
  }

  statement {
    sid       = "BoundedRolesByPath"
    effect    = "Allow"
    actions   = local.bounded_role_path_actions
    resources = local.offers_platform_bounded_role_arns
  }

  statement {
    sid       = "BoundedProfiles"
    effect    = "Allow"
    actions   = local.instance_profile_actions
    resources = ["arn:aws:iam::${local.offers_platform_account_id}:instance-profile${var.engineering_role_path}*"]
  }

  statement {
    sid       = "ServiceLinkedRoles"
    effect    = "Allow"
    actions   = ["iam:CreateServiceLinkedRole"]
    resources = ["arn:aws:iam::${local.offers_platform_account_id}:role/aws-service-role/*"]
  }

  statement {
    sid       = "IamRead"
    effect    = "Allow"
    actions   = local.iam_read_actions
    resources = ["*"]
  }

  statement {
    sid       = "DenyUsersKeysBoundaries"
    effect    = "Deny"
    actions   = local.deny_iam_user_and_boundary_actions
    resources = ["*"]
  }

  statement {
    sid       = "DenyBoundaryEdits"
    effect    = "Deny"
    actions   = local.deny_boundary_policy_edit_actions
    resources = [local.offers_platform_boundary_arn]
  }

  statement {
    sid       = "DenyOrgAccountSso"
    effect    = "Deny"
    actions   = local.deny_organization_account_identity_center_actions
    resources = ["*"]
  }

  statement {
    sid       = "DenyBilling"
    effect    = "Deny"
    actions   = local.deny_billing_change_actions
    resources = ["*"]
  }
}

# ----------------------------------------------------------- A: ABC Bank only

data "aws_iam_policy_document" "abc_bank_services" {
  statement {
    sid       = "DataServices"
    effect    = "Allow"
    actions   = ["rds:*", "dms:*", "secretsmanager:*", "logs:*"]
    resources = ["*"]
  }

  statement {
    sid       = "Ec2Read"
    effect    = "Allow"
    actions   = ["ec2:Describe*", "ec2:Get*"]
    resources = ["*"]
  }

  # Instances, security groups, network interfaces, interface endpoints and
  # EC2 Instance Connect endpoints. No VPC, subnet, route table, gateway or
  # peering actions.
  statement {
    sid       = "Ec2Session"
    effect    = "Allow"
    actions   = local.abc_bank_ec2_write_actions
    resources = ["*"]
  }

  # Laptop-to-private-subnet access path: Session Manager (both sides) and
  # EC2 Instance Connect Endpoint tunnels.
  statement {
    sid       = "AccessPath"
    effect    = "Allow"
    actions   = local.abc_bank_access_path_actions
    resources = ["*"]
  }

  # Use (not create, delete, disable or change) the ABC Bank key.
  statement {
    sid       = "KmsUse"
    effect    = "Allow"
    actions   = local.abc_bank_kms_use_actions
    resources = ["arn:aws:kms:us-east-1:${local.abc_bank_account_id}:key/*"]

    condition {
      test     = "ForAnyValue:StringEquals"
      variable = "kms:ResourceAliases"
      values   = ["alias/${var.abc_bank_kms_key_alias}"]
    }
  }

  statement {
    sid       = "KmsGrant"
    effect    = "Allow"
    actions   = ["kms:CreateGrant"]
    resources = ["arn:aws:kms:us-east-1:${local.abc_bank_account_id}:key/*"]

    condition {
      test     = "ForAnyValue:StringEquals"
      variable = "kms:ResourceAliases"
      values   = ["alias/${var.abc_bank_kms_key_alias}"]
    }

    condition {
      test     = "Bool"
      variable = "kms:GrantIsForAWSResource"
      values   = ["true"]
    }
  }

  statement {
    sid       = "StateBucket"
    effect    = "Allow"
    actions   = ["s3:ListBucket", "s3:GetBucketLocation"]
    resources = ["arn:aws:s3:::${var.abc_bank_state_bucket}"]
  }

  statement {
    sid       = "StateObjects"
    effect    = "Allow"
    actions   = ["s3:GetObject", "s3:PutObject", "s3:DeleteObject"]
    resources = ["arn:aws:s3:::${var.abc_bank_state_bucket}/*"]
  }

  statement {
    sid       = "RdsIamAuth"
    effect    = "Allow"
    actions   = ["rds-db:connect"]
    resources = ["arn:aws:rds-db:us-east-1:${local.abc_bank_account_id}:dbuser:*/*"]
  }

  statement {
    sid       = "CostTagRead"
    effect    = "Allow"
    actions   = ["ce:Get*", "ce:Describe*", "ce:List*", "tag:Get*"]
    resources = ["*"]
  }
}

# ---------------------------------------------------- P: Offers Platform only

data "aws_iam_policy_document" "offers_platform_services" {
  # The core of AWS's PowerUserAccess, replicated so the boundary can match it
  # exactly (decision D4).
  statement {
    sid         = "PowerUserCore"
    effect      = "Allow"
    not_actions = ["iam:*", "organizations:*", "account:*"]
    resources   = ["*"]
  }

  statement {
    sid    = "PowerUserExtras"
    effect = "Allow"
    actions = [
      "organizations:DescribeOrganization",
      "account:GetAccountInformation",
      "account:ListRegions",
      "iam:DeleteServiceLinkedRole",
      "iam:GetServiceLinkedRoleDeletionStatus",
    ]
    resources = ["*"]
  }

  # The NotAction allow above would otherwise grant this. The recovery role
  # holds AdministratorAccess, so it is denied explicitly (decision D8).
  statement {
    sid       = "DenyRecoveryRole"
    effect    = "Deny"
    actions   = ["sts:AssumeRole"]
    resources = ["arn:aws:iam::${local.offers_platform_account_id}:role/OrganizationAccountAccessRole"]
  }
}

# ------------------------------------------------------------ K: boundary only

data "aws_iam_policy_document" "deny_direct_abc_bank_key_use" {
  statement {
    sid       = "DenyDirectKmsUse"
    effect    = "Deny"
    actions   = local.kms_direct_use_actions
    resources = ["*"]

    condition {
      test     = "ForAnyValue:StringEquals"
      variable = "kms:ResourceAliases"
      values   = ["alias/${var.abc_bank_kms_key_alias}"]
    }

    condition {
      test     = "Null"
      variable = "kms:ViaService"
      values   = ["true"]
    }
  }
}

# ------------------------------------------------------------ assembled

# ABC Bank engineering inline policy = R + G + A.
data "aws_iam_policy_document" "abc_bank_engineering" {
  source_policy_documents = [
    data.aws_iam_policy_document.abc_bank_common.json,
    data.aws_iam_policy_document.abc_bank_services.json,
  ]
}

# Offers Platform engineering inline policy = R + G + P.
data "aws_iam_policy_document" "offers_platform_engineering" {
  source_policy_documents = [
    data.aws_iam_policy_document.offers_platform_common.json,
    data.aws_iam_policy_document.offers_platform_services.json,
  ]
}

# B-ABC = ABC Bank engineering inline policy + K.
data "aws_iam_policy_document" "abc_bank_boundary" {
  source_policy_documents = [
    data.aws_iam_policy_document.abc_bank_engineering.json,
    data.aws_iam_policy_document.deny_direct_abc_bank_key_use.json,
  ]
}

# B-OP = Offers Platform engineering inline policy + K.
data "aws_iam_policy_document" "offers_platform_boundary" {
  source_policy_documents = [
    data.aws_iam_policy_document.offers_platform_engineering.json,
    data.aws_iam_policy_document.deny_direct_abc_bank_key_use.json,
  ]
}
