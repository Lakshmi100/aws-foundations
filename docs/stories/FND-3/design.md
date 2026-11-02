# Design: FND-3 AWS organization, accounts and Identity Center access

Revision 2: updated for the owner's design-gate resolutions in `design-feedback.md` (round 1). The changes are recorded as D3 (confirmed), D5, D6 and D7 in section 8.

Revision 3: updated for the owner's decisions on the implementation escalations (`design-feedback.md`, "Implementation escalations"):
- Offers Platform engineering policy P, and so B-OP, gains an explicit deny on `sts:AssumeRole` for `OrganizationAccountAccessRole` (3.4, D8).
- The ABC Bank boundary size (6,097 of 6,144 characters) is accepted for FND-3. ABC-6 must choose a fallback before it adds permissions (section 5, D8).
- New variable `offers_platform_account_email` (3.3).
- Accepted implementation deviations, now part of the contract:
  - the management-account ID check is a `postcondition`, not a `precondition` (3.3);
  - `prevent_destroy` is on all three Administrator assignments (the `for_each` resource), not only the management one (3.1, 3.3);
  - the README gives explicit `-target` sets for setup steps 3 and 5. Until the member-account profiles work, the member provider profiles are pointed at `fnd-management-admin` through `TF_VAR_*` (3.8);
  - setup step 1 adds "IAM user and role access to Billing information" in the management account (3.8).

## 1. Analysis

The story builds the organization (all features, consolidated billing). It creates the ABC Bank account, brings in the existing Offers Platform account by invitation, and sets up Identity Center sign-in with MFA for one engineer. It adds five permission set assignments (Administrator in all three accounts, plus one engineering role in each member account) and a permissions boundary in each member account, capped to that account's engineering role. It also creates `OrganizationAccountAccessRole` in the invited account, turns on CloudTrail trusted access and Cost Explorer, sets up S3 state with locking, and adds a `README.md` with the manual steps, recovery steps and the Offers Platform IAM inventory.

The story does not ask for OUs, custom SCPs, a tag policy, the organization trail, budgets, member-account state buckets, GitHub OIDC, or any change to v1/v2 roles, users or keys.

This is the first story in the repo, so it sets the **reference pattern** (section 3.1) and adds the `Makefile` and `tests/FND-3.sh`. Of the four story-review questions, the owner resolved Q2 and Q3 at the design gate (section 6, rows 2 and 5). Q1 and Q4 are still open. Where the design needs a choice on those, it states an assumption and lists it in section 6. It does not answer them for the owner.

## 2. Impact

| Component | Files | Change |
|-----------|-------|--------|
| Reference pattern | `bootstrap/*.tf`, `organization/*.tf` | New. Sets the root layout, versions, backend, tags and variables that later roots copy |
| State root | `bootstrap/` | New. State bucket, its policy, versioning, encryption, public access block |
| Organization root | `organization/` | New. Organization, the three accounts (management imported for tags only), Identity Center user, 3 permission sets, 5 assignments, 2 boundary policies, Offers Platform `OrganizationAccountAccessRole` |
| Commands | `Makefile` | New. `make test`, `make lint` |
| Acceptance tests | `tests/FND-3.sh` | New. One PASS/FAIL/MANUAL line per AC (AC1 to AC16, with AC7b), then the regression lines (3.7) |
| Docs | `README.md` | Extended. Manual steps, pre-apply baseline, first-apply order, CLI profiles, recovery, Offers Platform inventory |
| Ignore rules | `.gitignore` | No change (`*.tfvars`, state and `.terraform/` are already ignored; `!example.tfvars` kept). The baseline lives outside the repo, so it needs no ignore rule |
| Member accounts | Offers Platform, ABC Bank | Offers Platform: joins the org and gains 3 IAM objects plus 2 SSO roles; nothing existing changes. ABC Bank: new |

## 3. Contract

### 3.1 Reference pattern (every Terraform root)

| File | Content |
|------|---------|
| `versions.tf` | `required_version = ">= 1.10, < 2.0"` (needed for S3-native locking). `hashicorp/aws` `~> 6.0`. Commit `.terraform.lock.hcl`. |
| `backend.tf` | `backend "s3" { bucket = "aws-foundations-tfstate-lakshmi100", key = "<root>/terraform.tfstate", region = "us-east-1", use_lockfile = true, encrypt = true }`. No DynamoDB table. No profile in the backend: credentials come from `AWS_PROFILE`. |
| `providers.tf` | Default `aws` provider: `region = "us-east-1"`, `default_tags { tags = var.cost_tags }`. Member-account aliases (organization root only) are listed in 3.3. |
| `variables.tf` | Every variable has `description` and `type`. `cost_tags` (`map(string)`) defaults to `{data-product = "aws-foundations", environment = "shared", owner = "Lakshmi100", cost-center = "offers-platform-portfolio"}`. |
| `outputs.tf` | Every output has a `description`. |
| `example.tfvars` | Only in roots with personal inputs. Shows every required variable with placeholder values. The real values go in `terraform.tfvars` (untracked). |
| Safety | Accounts (including the imported management account), the organization, the state bucket, the Administrator permission set and **all three Administrator assignments** (the `for_each` resource; revision 3) have `lifecycle { prevent_destroy = true }`. |

State keys: `bootstrap/terraform.tfstate` and `organization/terraform.tfstate`. FND-4 adds `guardrails/terraform.tfstate`.

### 3.2 `bootstrap/` (management account)

| Resource | Settings |
|----------|----------|
| `aws_s3_bucket.state` | Name `var.state_bucket_name` (default `aws-foundations-tfstate-lakshmi100`; must equal the backend `bucket`), `force_destroy = false` |
| `aws_s3_bucket_versioning` | `Enabled` |
| `aws_s3_bucket_server_side_encryption_configuration` | `AES256` (SSE-S3; a customer-managed KMS key would cost $1 per month) |
| `aws_s3_bucket_public_access_block` | All four settings `true` |
| `aws_s3_bucket_ownership_controls` | `BucketOwnerEnforced` |
| `aws_s3_bucket_policy` | (1) Deny `s3:*` on the bucket and `bucket/*` when `aws:SecureTransport = false`. (2) Deny `s3:*` on the same resources when `ArnNotLike aws:PrincipalArn` matches none of `arn:aws:iam::<mgmt>:role/aws-reserved/sso.amazonaws.com/*AWSReservedSSO_Administrator_*` and `arn:aws:iam::<mgmt>:root`. `<mgmt>` comes from `data.aws_caller_identity`, never a literal. |

Outputs: `state_bucket_name`, `state_bucket_arn`. Variables: `state_bucket_name`, `cost_tags`.

### 3.3 `organization/` resources

Providers: the default provider is the management account (`AWS_PROFILE`, the Administrator profile). Two aliases, `aws.abc_bank` (`profile = var.abc_bank_admin_profile`) and `aws.offers_platform` (`profile = var.offers_platform_admin_profile`), use the Identity Center Administrator profiles for those accounts (decision D2). For each alias, `data "aws_caller_identity"` plus a `precondition` on every member-account resource checks that the alias's account ID equals the matching `aws_organizations_account` ID. If a profile points at the wrong account, the plan fails.

| Resource | Contract |
|----------|----------|
| `aws_organizations_organization.this` | Imported. `feature_set = "ALL"`; `aws_service_access_principals = ["cloudtrail.amazonaws.com", "sso.amazonaws.com"]`; `enabled_policy_types = ["SERVICE_CONTROL_POLICY"]`, so AWS attaches its default `FullAWSAccess` and nothing is restricted (constraint "Effect on member accounts"). No custom SCPs. FND-4 adds any further service principals to this list in this root. |
| `aws_organizations_account.management` | Imported by the management account ID. **Tags only** (D5). `name` and `email` come from variables so the import matches. `close_on_deletion = false`. `ignore_changes = [name, email, role_name, iam_user_access_to_billing]`. `prevent_destroy = true`. `postcondition` (revision 3, accepted deviation; the ID is only known once the resource is read): its `id` equals `aws_organizations_organization.this.master_account_id`. Never removed by `destroy`; if it ever has to leave state, use `terraform state rm` or a `removed` block with `destroy = false`. |
| `aws_organizations_account.abc_bank` | `name = var.abc_bank_account_name` (default `"ABC Bank"`), `email = var.abc_bank_account_email`, `role_name = "OrganizationAccountAccessRole"`, `iam_user_access_to_billing = "ALLOW"` (so IAM roles can read Cost Explorer), `close_on_deletion = false`. `ignore_changes = [role_name, iam_user_access_to_billing]`. |
| `aws_organizations_account.offers_platform` | Imported after the account accepts the invitation. `name = var.offers_platform_account_name`, `email = var.offers_platform_account_email` (the resource requires an email). `ignore_changes = [name, email, role_name, iam_user_access_to_billing]`. Tags only. |
| `aws_identitystore_user.engineer` | Imported. `user_name`, `display_name`, `name.given_name`, `name.family_name` and the primary `emails` come from variables. (Identity Store users cannot be tagged.) |
| `aws_ssoadmin_permission_set` × 3 | `Administrator` (`PT1H`); `ABCBankEngineering` (`PT4H`); `OffersPlatformEngineering` (`PT4H`). Each has a description stating its purpose (Administrator: "Setup, recovery and long-lived foundations. Not for day-to-day work."). All three carry the four cost tags through `default_tags`; the imported `Administrator` set gains them on the first apply. |
| `aws_ssoadmin_managed_policy_attachment` | Administrator gets `arn:aws:iam::aws:policy/AdministratorAccess`. |
| `aws_ssoadmin_permission_set_inline_policy` × 2 | Engineering policies from section 3.4 |
| `aws_ssoadmin_account_assignment` | `USER` = engineer. Administrator goes to the management account, `abc_bank` and `offers_platform` (`for_each` keys `management`, `abc_bank`, `offers_platform`; `prevent_destroy` on the resource, so all three keys are protected). `ABCBankEngineering` goes to `abc_bank`. `OffersPlatformEngineering` goes to `offers_platform`. No group. |
| `aws_iam_policy.boundary_abc_bank` (alias `abc_bank`) | Name `EngineeringPermissionsBoundary`, path `/`, document 3.4 B-ABC |
| `aws_iam_policy.boundary_offers_platform` (alias `offers_platform`) | Same name and path, document 3.4 B-OP |
| `aws_iam_role.offers_platform_oaar` (alias `offers_platform`) | Name `OrganizationAccountAccessRole`, path `/`. Trust: `sts:AssumeRole` from `arn:aws:iam::<mgmt>:root`, where `<mgmt>` comes from the default provider's caller identity. `max_session_duration = 3600`. Attached `AdministratorAccess`. |

Identity Center, its MFA setting and the organization itself cannot be created by API in a way that fits this order (section 3.8), so they are created by hand and then imported.

**Identity Center instance tags (D5).** The provider has no resource that manages the Identity Center instance (only the `aws_ssoadmin_instances` data source), so Terraform does not hold it. The instance is tagged once by a documented CLI step (3.8 step 3), with the values from `var.cost_tags`:

    aws sso-admin tag-resource --instance-arn <sso_instance_arn> --resource-arn <sso_instance_arn> \
      --tags Key=data-product,Value=aws-foundations Key=environment,Value=shared \
             Key=owner,Value=Lakshmi100 Key=cost-center,Value=offers-platform-portfolio

Because the instance is not in state, this step cannot cause plan changes (AC16). AC14 reads the tags back, so drift is caught by the test, not by `plan`.

Variables (`organization/`): `management_account_name`, `management_account_email` (to match the import; `sensitive`), `abc_bank_account_name`, `abc_bank_account_email`, `offers_platform_account_name`, `offers_platform_account_email` (revision 3; `sensitive`; required by the account resource, changes ignored), `engineer_user_name`, `engineer_given_name`, `engineer_family_name`, `engineer_email`, `abc_bank_admin_profile` (default `fnd-abc-bank-admin`), `offers_platform_admin_profile` (default `fnd-offers-platform-admin`), `boundary_policy_name` (default `EngineeringPermissionsBoundary`), `engineering_role_path` (default `/eng/`), `abc_bank_kms_key_alias` (default `abc-bank-kms-key`), `abc_bank_state_bucket` (default `abc-bank-offers-platform`), `cost_tags`. The emails and names are marked `sensitive = true`.

Outputs: `organization_id`, `management_account_id`, `abc_bank_account_id`, `offers_platform_account_id`, `identity_store_id`, `sso_instance_arn`, `permission_set_arns` (map by name), `boundary_policy_arns` (map `abc_bank`/`offers_platform`), `offers_platform_oaar_arn`.

### 3.4 Policy contract

All documents are built with `data "aws_iam_policy_document"` from shared statement blocks in `organization/policies.tf`. Each **boundary is the same allow statements as its engineering role, plus the boundary-only denies**, so the cap cannot drift (decision D4). The boundary ARN is `arn:aws:iam::<acct>:policy/EngineeringPermissionsBoundary`, with `<acct>` taken from the account resource. A "bounded role" is a role under path `/eng/` (decision D3, confirmed by the owner).

The contract is the effect, actions, resources and conditions below. Statement IDs (`Sid`) are not part of the contract; the implementer may shorten or rename them, and tests must not depend on them.

**R: role management (in both engineering roles and both boundaries)**

| Effect | Actions | Resource | Condition |
|--------|---------|----------|-----------|
| Allow | `iam:CreateRole` | `role/eng/*` (+ ABC Bank only: `role/dms-vpc-role`, `role/dms-cloudwatch-logs-role`) | `StringEquals iam:PermissionsBoundary = <boundary ARN>` |
| Allow | `iam:AttachRolePolicy`, `iam:DetachRolePolicy`, `iam:PutRolePolicy`, `iam:DeleteRolePolicy` | same | same |
| Allow | `iam:DeleteRole`, `iam:UpdateRole`, `iam:UpdateRoleDescription`, `iam:UpdateAssumeRolePolicy`, `iam:TagRole`, `iam:UntagRole`, `iam:PassRole` | same | none (the path scopes it; these actions do not support `iam:PermissionsBoundary`) |
| Allow | `iam:CreateInstanceProfile`, `iam:DeleteInstanceProfile`, `iam:AddRoleToInstanceProfile`, `iam:RemoveRoleFromInstanceProfile`, `iam:TagInstanceProfile`, `iam:UntagInstanceProfile` | `instance-profile/eng/*` | none |
| Allow | `iam:CreateServiceLinkedRole` | `role/aws-service-role/*` | none |
| Allow | `iam:Get*`, `iam:List*`, `iam:GenerateCredentialReport`, `iam:GenerateServiceLastAccessedDetails` | `*` | none |

Roles at path `/` (including `OrganizationAccountAccessRole` and v1/v2 roles) and `/aws-reserved/` are outside every allow. Policy, trust and deletion changes on them are therefore denied by default.

**G: guard denies (in both engineering roles and both boundaries)**

| Actions (Deny, Resource `*` unless stated) |
|---------|
| `iam:CreateUser`, `iam:CreateAccessKey`, `iam:CreateLoginProfile`, `iam:PutRolePermissionsBoundary`, `iam:DeleteRolePermissionsBoundary`, `iam:PutUserPermissionsBoundary`, `iam:DeleteUserPermissionsBoundary` |
| `iam:CreatePolicyVersion`, `iam:DeletePolicy`, `iam:DeletePolicyVersion`, `iam:SetDefaultPolicyVersion`, `iam:TagPolicy`, `iam:UntagPolicy`, on the boundary policy ARN |
| `organizations:Accept*`, `Attach*`, `Cancel*`, `Close*`, `Create*`, `Decline*`, `Delete*`, `Deregister*`, `Detach*`, `Disable*`, `Enable*`, `Invite*`, `Leave*`, `Move*`, `Put*`, `Register*`, `Remove*`, `Tag*`, `Untag*`, `Update*` |
| `account:Accept*`, `account:Close*`, `account:Delete*`, `account:Disable*`, `account:Enable*`, `account:Put*`, `account:Start*` |
| `sso:*`, `sso-directory:*`, `identitystore:*` |
| Billing writes: `aws-portal:Modify*`, `billing:Create*`, `Delete*`, `Put*`, `Redeem*`, `Update*`, `payments:Create*`, `Delete*`, `Make*`, `Update*`, `tax:Batch*`, `Delete*`, `Put*`, `Update*`, `invoicing:Create*`, `Delete*`, `Put*`, `Update*`, `purchase-orders:Add*`, `Create*`, `Delete*`, `Modify*`, `Update*`, `cur:Delete*`, `Modify*`, `Put*`, `ce:Create*`, `ce:Delete*`, `ce:Update*`, `freetier:Put*` |

Reads are not denied (`ce:Get*`, `budgets:ViewBudget`, `organizations:Describe*` and `List*`).

Neither engineering role is granted `iam:CreatePolicy`, `iam:CreatePolicyVersion` or `iam:DeletePolicy` on any policy (owner decision, section 6 row 2). Bounded roles use inline policies or attach existing managed policies.

**ABC Bank engineering inline policy = R + G + A**

| Effect | Actions | Resource / condition |
|--------|---------|----------|
| Allow | `rds:*`, `dms:*`, `secretsmanager:*`, `logs:*` | `*` |
| Allow | `ec2:Describe*`, `ec2:Get*` | `*` |
| Allow | `ec2:RunInstances`, `StartInstances`, `StopInstances`, `RebootInstances`, `TerminateInstances`, `ModifyInstanceAttribute`, `AssociateIamInstanceProfile`, `DisassociateIamInstanceProfile`, `ReplaceIamInstanceProfileAssociation`, `CreateSecurityGroup`, `DeleteSecurityGroup`, `AuthorizeSecurityGroupIngress`, `AuthorizeSecurityGroupEgress`, `RevokeSecurityGroupIngress`, `RevokeSecurityGroupEgress`, `ModifySecurityGroupRules`, `UpdateSecurityGroupRuleDescriptionsIngress`, `UpdateSecurityGroupRuleDescriptionsEgress`, `CreateNetworkInterface`, `DeleteNetworkInterface`, `ModifyNetworkInterfaceAttribute`, `AttachNetworkInterface`, `DetachNetworkInterface`, `CreateVpcEndpoint`, `ModifyVpcEndpoint`, `DeleteVpcEndpoints`, `CreateInstanceConnectEndpoint`, `DeleteInstanceConnectEndpoint`, `CreateTags`, `DeleteTags` (all `ec2:`) | `*`. No VPC, subnet, route table, gateway or peering actions. |
| Allow | `ssm:StartSession`, `ssm:TerminateSession`, `ssm:ResumeSession`, `ssm:DescribeSessions`, `ssm:DescribeInstanceInformation`, `ssm:GetConnectionStatus`, `ssm:UpdateInstanceInformation`, `ssmmessages:*`, `ec2messages:*`, `ec2-instance-connect:OpenTunnel`, `ec2-instance-connect:SendSSHPublicKey` | `*` (open question 6) |
| Allow | `kms:Encrypt`, `Decrypt`, `ReEncrypt*`, `GenerateDataKey*`, `DescribeKey`, `CreateGrant` | `arn:aws:kms:us-east-1:<abc>:key/*`, `ForAnyValue:StringEquals kms:ResourceAliases = alias/abc-bank-kms-key`. `CreateGrant` also needs `Bool kms:GrantIsForAWSResource = true`. No other KMS actions, so key creation, deletion, disabling and policy changes are implicitly denied. |
| Allow | `s3:ListBucket`, `s3:GetBucketLocation` on `arn:aws:s3:::abc-bank-offers-platform`; `s3:GetObject`, `s3:PutObject`, `s3:DeleteObject` on `.../*` | none |
| Allow | `rds-db:connect` | `arn:aws:rds-db:us-east-1:<abc>:dbuser:*/*` |
| Allow | `ce:Get*`, `ce:Describe*`, `ce:List*`, `tag:Get*` | `*` |

ABC Bank grants no `sts` actions, so it needs no recovery-role deny (D8).

**Offers Platform engineering inline policy = R + G + P**

| Effect | Actions | Resource |
|--------|---------|----------|
| Allow | `NotAction: [iam:*, organizations:*, account:*]` | `*` (the core of `PowerUserAccess`) |
| Allow | `organizations:DescribeOrganization`, `account:GetAccountInformation`, `account:ListRegions`, `iam:DeleteServiceLinkedRole`, `iam:GetServiceLinkedRoleDeletionStatus` | `*` |
| Deny | `sts:AssumeRole` | `arn:aws:iam::<offers_platform>:role/OrganizationAccountAccessRole`, with `<offers_platform>` taken from the account resource (revision 3, D8). The `NotAction` allow above otherwise grants it. TC49 (AC10) stays as approved. |

**Boundaries**
- **B-ABC** = ABC Bank inline policy (R + G + A) + **K**.
- **B-OP** = Offers Platform inline policy (R + G + P) + **K**. Because it is built from the same statements, B-OP includes the `sts:AssumeRole` deny on `OrganizationAccountAccessRole`.
- **K** = Deny `kms:Encrypt`, `kms:Decrypt`, `kms:ReEncrypt*`, `kms:GenerateDataKey*` on `*` when `ForAnyValue:StringEquals kms:ResourceAliases = alias/abc-bank-kms-key` and `Null kms:ViaService = true`. Direct calls are denied; service calls through RDS, DMS or EBS (which carry `kms:ViaService`) and grants still work.

Each boundary must stay under the 6,144-character managed-policy limit (B-ABC is at 6,097; see section 5). Both engineering inline policies must stay under the 32,768-character permission-set limit.

### 3.5 CLI profiles (documented in README; used by Terraform and tests)

`fnd-management-admin`, `fnd-abc-bank-admin`, `fnd-offers-platform-admin`, `fnd-abc-bank-engineering`, `fnd-offers-platform-engineering`. All five use one `sso-session fnd` (region `us-east-1`). The test script reads them from environment variables of the same names in upper snake case (`FND_MANAGEMENT_ADMIN` etc.) and defaults to these names.

### 3.6 `Makefile`

- `ROOTS := bootstrap organization`
- `make test`: for each root, run `terraform -chdir=$(root) init -backend=false -input=false`, then `terraform -chdir=$(root) validate`.
- `make lint`: `terraform fmt -check -recursive`.

Neither target needs AWS credentials.

### 3.7 `tests/FND-3.sh`

- Starts with `#!/usr/bin/env bash` and `set -euo pipefail`.
- Prints exactly one line per AC, in the format `PASS|FAIL|MANUAL <ACid> <text>`, in order AC1 to AC16 with AC7b after AC7 (17 lines). A FAIL lists the sub-checks that failed.
- After the 17 AC lines it prints the regression lines `PASS|FAIL REG-TC67 <text>` and `PASS|FAIL REG-TC68 <text>` (open question 8). They are not AC lines, so the AC line count stays 17.
- Exits 1 if any line is FAIL.
- Denials use `aws iam simulate-principal-policy` against the SSO role ARN, found with `aws iam list-roles --path-prefix /aws-reserved/sso.amazonaws.com/` and the `AWSReservedSSO_<PermissionSetName>_` name prefix. Boundary checks use `simulate-custom-policy` with `--permissions-boundary-policy-input-list`.
- Test resource ARNs follow the contract (owner-confirmed convention, D3):
  - "With the boundary" checks use `arn:aws:iam::<acct>:role/eng/fnd3-sim` (and `instance-profile/eng/fnd3-sim`) plus context `iam:PermissionsBoundary=<boundary ARN>` where the action supports it.
  - "Without the boundary" checks use `role/fnd3-sim` at path `/` with no context, or `role/OrganizationAccountAccessRole`.
  - KMS checks pass context `kms:ResourceAliases=alias/abc-bank-kms-key`, with no `kms:ViaService`.
  - The capped-action example is `ec2:CreateVpc` in ABC Bank and `iam:CreateOpenIDConnectProvider` in Offers Platform.
- **AC5 to AC7 run the AC's own list plus the test plan's extra checks, and every sub-check must hold for PASS (D6).** The extras are:

  | AC | TC | Role | Sub-checks | Expected |
  |----|----|------|-----------|----------|
  | AC5 | TC20 | ABC Bank engineering | `iam:PassRole`, `iam:DeleteRole`, `iam:UpdateRole` on `role/eng/fnd3-sim`; `iam:CreateInstanceProfile` on `instance-profile/eng/fnd3-sim`; `ec2-instance-connect:OpenTunnel`; `ec2:RunInstances`, `ec2:CreateNetworkInterface`, `ec2:CreateVpcEndpoint`; `iam:GetRole`, `iam:ListRoles` | allowed |
  | AC6 | TC25 | ABC Bank engineering | on ABC Bank `role/OrganizationAccountAccessRole`: `iam:AttachRolePolicy`, `iam:PutRolePolicy`, `iam:UpdateAssumeRolePolicy`, `iam:DeleteRole`, `iam:PutRolePermissionsBoundary` | denied |
  | AC6 | TC26 | ABC Bank engineering | `kms:DisableKey`, `kms:CreateKey`, `organizations:CreateAccount`, `sso:CreateAccountAssignment`, `sso:DeletePermissionSet`, `account:PutAlternateContact` | denied |
  | AC6 | TC27 | ABC Bank engineering | `iam:CreatePolicyVersion`, `iam:DeletePolicy` on the boundary policy ARN; `iam:CreatePolicy` on `policy/fnd3-sim` | denied (firm, not MANUAL) |
  | AC7 | TC32 | Offers Platform engineering | `iam:GetRole`, `iam:ListRoles`, `iam:ListUsers`; `iam:AttachRolePolicy`, `iam:DetachRolePolicy`, `iam:PutRolePolicy`, `iam:DeleteRolePolicy`, `iam:DeleteRole` on `role/eng/fnd3-sim`; `iam:CreateInstanceProfile` on `instance-profile/eng/fnd3-sim`; `ce:GetCostAndUsage`, `budgets:ViewBudget`; `kms:CreateKey` | allowed |
  | AC7 | TC33 | Offers Platform engineering | on `role/OrganizationAccountAccessRole` and on the first role in the baseline (3.8 step 0) not under `/eng/`: `iam:AttachRolePolicy`, `iam:PutRolePolicy`, `iam:UpdateAssumeRolePolicy`, `iam:DeleteRole` | denied |
  | AC7 | TC34 | Offers Platform engineering | `sso:CreateAccountAssignment`, `sso:DeletePermissionSet`, `organizations:CreateAccount`, `account:PutAlternateContact`, `aws-portal:ModifyAccount`, `billing:PutContractInformation`, `iam:CreatePolicyVersion` on the boundary policy ARN | denied (all firm, not MANUAL) |

  TC33 prints the role by name only in its FAIL text if needed; it never prints ARNs or account IDs.
- AC13 engineering-role `s3:GetObject`: pass `--resource-policy` (the bucket policy) and `--resource-owner` (the management account ARN).
- AC13 lock: start `sleep 60 | terraform console` in `bootstrap/` (it holds the lock), then run `terraform apply -input=false -lock-timeout=0s` and expect `Error acquiring the state lock`. Then kill the console. No resources are created.
- AC14 reads tags with the service's own call (test plan TC62) and requires all four keys with the exact values and case:
  - state bucket: `s3api get-bucket-tagging`; no lock table exists (D1), so none is read;
  - all three accounts, **including the management account**: `organizations list-tags-for-resource --resource-id <account id>`;
  - the Identity Center instance and the three permission sets: `sso-admin list-tags-for-resource --instance-arn <instance> --resource-arn <arn>`;
  - both boundary policies: `iam list-policy-tags` (member-account admin profiles);
  - Offers Platform `OrganizationAccountAccessRole`: `iam list-role-tags`.
  - Cross-check: every taggable resource type in `terraform state list` for both roots appears in the list above.
- **Regression lines (TC67, TC68).** They read the baseline from `${FND3_BASELINE_DIR:-$HOME/.fnd-3-baseline}` (3.8 step 0). Missing or unreadable baseline: FAIL with "baseline missing". REG-TC67 compares Offers Platform users and access keys (ID, status): same users, same keys, nothing that was `Active` is now `Inactive` or gone. REG-TC68 compares every baseline role: no permissions boundary, same trust policy, same attached and inline policies. Output names counts and role names only, never key IDs or ARNs.
- MANUAL lines: AC3, AC8, AC11, AC15.

### 3.8 First-apply order and teardown (README "Setup")

0. **Owner, before step 3 sends the invitation, inside Offers Platform: pre-apply baseline (D7).**
   - Who: the owner, using the existing Offers Platform credentials they use today. Read-only calls only; nothing is created or changed. Not root.
   - Where: `${FND3_BASELINE_DIR:-$HOME/.fnd-3-baseline}`, a directory **outside the repo working tree**. It is never committed, because it holds full key IDs, ARNs and the account ID, and the repo is public. The README gives the commands but never the output.
   - What, one JSON file each:
     - `users.json`: `aws iam list-users` (UserName, CreateDate);
     - `access-keys.json`: for each user, `aws iam list-access-keys` (UserName, AccessKeyId, Status, CreateDate);
     - `roles.json`: for each role from `aws iam list-roles` outside `/aws-reserved/` and `/aws-service-role/`: `get-role` (Path, AssumeRolePolicyDocument, PermissionsBoundary), `list-attached-role-policies`, `list-role-policies` and each `get-role-policy` document.
   - The roles in `roles.json` are, by definition, the "existing v1/v2 roles" for TC33, TC68 and the README inventory (AC8). This story's roles do not exist yet, so they are excluded automatically.
   - The same data feeds the README inventory (3.9), after the owner redacts it to the open question 4 fields.
1. **Owner, by hand, as root in the console, once** (assumption, open question 1):
   - sign up and set root MFA;
   - turn on "IAM user and role access to Billing information" in the management account's account settings (revision 3, accepted deviation);
   - enable Identity Center in `us-east-1` (this creates the organization with all features);
   - set MFA "every time they sign in", with authenticator apps or security keys, and "require registration at sign-in";
   - create the engineer user, the `Administrator` permission set (`PT1H`, `AdministratorAccess`) and its management-account assignment;
   - enable Cost Explorer;
   - sign out of root.
2. **Admin profile:** apply `bootstrap/` with `backend.tf` moved aside. Restore `backend.tf`, then run `terraform init -migrate-state`.
3. **Admin profile:**
   - In `organization/`, run `terraform import` for the organization, the **management account** (`aws_organizations_account.management`), the user, the `Administrator` permission set, its managed-policy attachment and its management assignment. The README gives the commands and the CLI calls that look up each ID.
   - Apply with the explicit `-target` set the README lists for this step (the ABC Bank account, then the Identity Center resources). This apply also adds the four tags to the management account and the imported `Administrator` permission set.
   - Until the member-account profiles work (they need the member Administrator assignments to exist), set `TF_VAR_abc_bank_admin_profile=fnd-management-admin` and `TF_VAR_offers_platform_admin_profile=fnd-management-admin` so the member provider aliases can initialise (revision 3, accepted deviation). The `-target` sets contain no member-account resources; if a plan reaches one, the account-ID precondition (3.3) fails it.
   - Tag the Identity Center instance with the `aws sso-admin tag-resource` command in 3.3. Check it with `aws sso-admin list-tags-for-resource`.
   - Send the invitation with `aws organizations invite-account-to-organization` (Terraform has no invitation resource).
4. **Owner, inside Offers Platform:** accept the invitation.
5. **Admin profile:** import `aws_organizations_account.offers_platform`, then apply the explicit `-target` set the README lists for this step, with the same `TF_VAR_*` overrides while the member profiles do not work yet. Once `fnd-abc-bank-admin` and `fnd-offers-platform-admin` sign in, unset the overrides and run a full `apply` (boundaries, Offers Platform OAAR). After this, `plan` shows no changes.
6. **Owner:** set root MFA in ABC Bank (password recovery on its email), and confirm root MFA and no root keys in Offers Platform.

Teardown: none. Everything is long-lived. `prevent_destroy` and `close_on_deletion = false` stop accidental removal (AGENTS.md boundary). The baseline directory may be kept by the owner as evidence; it is never uploaded to the repo or the PR.

### 3.9 `README.md` sections

Manual steps (3.8 steps 0, 1, 4, 6, the Identity Center instance tag step, and Cost Explorer), Setup order, CLI profiles, **Recovery**, and **Offers Platform IAM inventory**.

- **Recovery** covers two paths:
  - management account: root plus MFA, then fix Identity Center or the permission set;
  - member accounts: from `fnd-management-admin`, run `aws sts assume-role --role-arn arn:aws:iam::<member>:role/OrganizationAccountAccessRole`.
- **Offers Platform IAM inventory** has three tables:
  - users: name, created;
  - access keys: user, last 4 characters of the key ID, status, last used date, last used service and region;
  - v1/v2 roles: name and path only, with no ARNs or account IDs.

  The data comes from the 3.8 step 0 baseline plus `aws iam generate-credential-report` and `get-credential-report`, and `get-access-key-last-used`. These fields are an assumption (open question 4).

## 4. Data model

There is no application data. New persistent state:
- the state bucket (two state files, plus `.tflock` objects while a run is active);
- the organization and its accounts (the management account in state for tags only);
- one Identity Store user;
- three permission sets and five assignments;
- in each member account, one managed policy and two SSO-managed roles;
- in Offers Platform, `OrganizationAccountAccessRole`.

Outside Terraform: four tags on the Identity Center instance (CLI step), and the owner's local baseline directory (outside the repo).

Effect on existing data:
- Management account: gains four account tags; nothing else changes (all other attributes ignored).
- Offers Platform: its billing moves to the management account's consolidated bill from the join date. Its IAM users, keys and v1/v2 roles are only read (once for the baseline, again by the tests).
- State holds the engineer's name and email and the account emails, including the management account's and the Offers Platform account's. Only the management Administrator role and root can read it (3.2).

## 5. Risks

| Risk | Mitigation / how tests catch it |
|------|------|
| Lock-out if the Administrator permission set or any of its assignments is changed or deleted | `prevent_destroy` on the permission set and all three Administrator assignments; recovery via root (AC11) and OAAR (AC10); AGENTS.md: never remove the last admin assignment |
| The bucket policy deny locks the admin out of state if the permission set is renamed | The name `Administrator` is fixed; root is still allowed and can edit the policy; AC13 checks admin access |
| AWS changes `PowerUserAccess` and the replica drifts from it | Accepted. The replica is the contract, and the boundary matches it by construction (D4) |
| The tester, working from the story alone, simulates role ARNs without `/eng/` and gets false FAILs | 3.7 fixes the ARNs (owner-confirmed, D3). The implementer aligns `tests/FND-3.sh` with this design |
| **The ABC Bank boundary renders at 6,097 of 6,144 characters** (with shortened statement IDs), leaving 47 characters of headroom | Accepted by the owner for FND-3 (D8). A boundary is one managed policy and cannot be split into two. Statement IDs are not part of the contract (3.4), so shortening them is allowed. **ABC-6 must choose a fallback before it adds any permission to the ABC Bank engineering role**, for example exact-match action wildcards (such as `ec2:*SecurityGroup*`, checked to match no unwanted action). If the limit is exceeded, `terraform apply` fails with `LimitExceeded`; nothing is half-applied |
| An Offers Platform engineer (or a bounded role) assumes `OrganizationAccountAccessRole` through the `NotAction` allow and gains `AdministratorAccess` | Explicit Deny `sts:AssumeRole` on that role in P and so in B-OP (3.4, D8); TC49 (AC10) checks it |
| Imported resources drift (organization service principals, permission set fields) | AC16 `plan` shows no changes; README gives exact values for the manual permission set |
| The management account in `aws_organizations_account` shows a diff on an attribute the API does not return (for example `close_on_deletion`, `parent_id`), or a `destroy` tries to remove it from the organization | `ignore_changes` on name, email, role, billing access; `close_on_deletion = false` set explicitly; if `plan` still shows a non-tag diff after import, the implementer adds that attribute to `ignore_changes` (tags must stay managed). `prevent_destroy` blocks removal; leaving state uses `state rm`/`removed { destroy = false }` only. The `postcondition` catches a wrong import ID. AC16 catches any remaining diff |
| The `TF_VAR_*` profile overrides (3.8 steps 3 and 5) are left set, so the member aliases point at the management account | The account-ID precondition on every member-account resource fails the plan; the README says to unset them before the full apply |
| The Identity Center instance tags are changed by hand and nothing in Terraform notices | AC14 reads them on every test run. If AWS rejects `tag-resource` on the instance ARN, the implementer stops and asks the owner rather than marking it not taggable |
| AC6/AC7 now include extra sub-checks (D6), so a small policy error fails the whole criterion | Intended: the sub-checks are the contract. The FAIL text names each failed sub-check |
| The baseline is taken late (after the invitation) or not at all, so TC67/TC68 have nothing to compare against | 3.8 step 0 comes before the invitation; REG lines FAIL with "baseline missing" rather than passing |
| The baseline leaks into the public repo | Stored outside the working tree by default; README warns not to set `FND3_BASELINE_DIR` inside the repo; TC71 (repo hygiene) checks for account IDs and credentials in tracked files |
| The Offers Platform account is on the AWS Free plan or in another organization, so the invitation fails | README step 3 checks with `aws organizations describe-organization` inside Offers Platform before inviting |
| An `OrganizationAccountAccessRole` already exists in Offers Platform | README step 5 runs `aws iam get-role` first; if it exists, stop and ask (do not import silently, since it may be in use). The baseline (step 0) shows it in advance |
| Member Cost Explorer reads depend on the management account's billing-access and linked-account access settings | README step 1 turns on "IAM user and role access to Billing information" and keeps linked-account access on; AC5 runs a real `ce get-cost-and-usage` from ABC Bank |
| The bucket name `aws-foundations-tfstate-lakshmi100` is taken globally | `bootstrap` apply fails. Pick a new name and update `var.state_bucket_name` and every `backend.tf` together |
| DMS needs `dms-vpc-role` at path `/` | Allowed by name in ABC Bank only, still with the boundary required. Not allowed in Offers Platform, where v1/v2 may already own such a role unbounded |
| Cost | The only billed resource is the bucket (KB-sized objects, SSE-S3, no DynamoDB, no KMS key): under $0.05 per month, which is under the $0.50 limit (AC15). Tags, the management-account import, the sts deny and the local baseline cost nothing |

## 6. Open questions

| # | Question | Recommended assumption |
|---|----------|------------------------|
| 1 | Story review Q1 (open): who runs the first `bootstrap/` and `organization/` applies, and with what credentials? | The owner does only console steps as root (3.8 step 1: billing access setting, Identity Center, which creates the org, the user, the Administrator permission set and its management assignment). Every Terraform run uses the Identity Center Administrator profile, and those objects are imported. Root runs no Terraform and creates no keys. The owner must confirm, because this puts more steps by hand than req 9's "only steps AWS allows only by hand". |
| 2 | **Resolved by the owner (design gate, feedback item 3).** Story review Q2: may the engineering roles create or change customer-managed policies, and may they edit the boundary policy? | Decision: neither role is given `iam:CreatePolicy`, `CreatePolicyVersion` or `DeletePolicy`. Edits to the boundary policy are explicitly denied (G). Bounded roles use inline policies or attach existing managed policies. TC27 and the `iam:CreatePolicyVersion` part of TC34 are firm denied checks (3.7). |
| 3 | Story review Q2 (open): for ABC Bank engineering, does "update" include policy and trust changes on bounded roles? | Yes, the same as for Offers Platform (R is shared). ABC-6's Terraform needs it. |
| 4 | Story review Q4 (open): what may the public `README.md` inventory contain? | User names, key ID last 4 characters, key status, last-used date, service and region, and role names and paths only. No full key IDs, ARNs or account IDs. The owner reviews the table before commit. If user names are personal, the owner may replace them with labels, and AC8 then compares by count and label. |
| 5 | **Resolved by the owner (design gate, feedback item 1).** Story review Q3 / test-plan Q3: checks for the round 1 additions and for denying changes to unbounded roles have no AC. | Decision: `tests/FND-3.sh` runs the test plan's extra checks TC20 (AC5), TC25, TC26, TC27 (AC6), TC32, TC33, TC34 (AC7), and they count towards the criterion's PASS (3.7, D6). The earlier "check only what the ACs list" no longer applies. |
| 6 | The access path needs the instance side of SSM (`ssm:UpdateInstanceInformation`, `ssmmessages:*`, `ec2messages:*`). Because of the cap, a bounded instance role can only have these if the engineering role has them too. | Include them in the ABC Bank engineering role and boundary (A). This adds a little to req 4's list. Allow both Session Manager and EIC Endpoint tunnels. |
| 7 | **Resolved by the owner (design gate, feedback item 2; answers test-plan Q5).** Bounded roles must live under path `/eng/` (D3). This is a new constraint on ABC-6 and later Terraform (`path = "/eng/"` on every role and instance profile). | Decision: path `/eng/` plus the `iam:PermissionsBoundary` condition where IAM supports it; tests use the role ARNs in 3.7. Add the path rule to the ABC-6 issue. The exceptions are the DMS default role names in ABC Bank. |
| 8 | Test plan TC67/TC68 are regressions with no AC, and TC72 expects exactly 17 lines (one per AC). Where do the regression results go? | Print them as two extra lines, `REG-TC67` and `REG-TC68`, after the 17 AC lines; they can FAIL the run (exit 1). TC72 counts only lines whose ID starts with `AC`. The tester confirms or adjusts TC72's wording. |

## 7. Sequence diagram

```mermaid
sequenceDiagram
    actor Owner
    participant Root as Mgmt root (console)
    participant Admin as Admin SSO profile + Terraform
    participant Org as Organizations / Identity Center
    participant OP as Offers Platform account
    participant ABC as ABC Bank account
    Owner->>OP: baseline IAM users, keys, roles (read-only, existing credentials) to local dir outside repo
    Owner->>Root: sign up, root MFA
    Root->>Org: billing access for IAM, enable Identity Center (creates org, ALL), MFA setting, user, Administrator PS + mgmt assignment, Cost Explorer
    Owner->>Admin: aws sso login (fnd-management-admin)
    Admin->>Admin: bootstrap/ apply (local) -> migrate state to S3
    Admin->>Org: organization/ import org, management account, user, PS, assignment
    Admin->>Org: targeted apply (TF_VAR_* member profiles = mgmt): ABC Bank account, permission sets, admin assignments, tags on mgmt account + PSs
    Admin->>Org: sso-admin tag-resource (Identity Center instance)
    Admin->>Org: invite-account-to-organization (Offers Platform)
    Owner->>OP: accept invitation (existing credentials)
    Admin->>Org: import Offers Platform account; targeted apply: engineering assignments
    Admin->>ABC: full apply: boundary policy (fnd-abc-bank-admin)
    Admin->>OP: full apply: boundary policy + OrganizationAccountAccessRole (fnd-offers-platform-admin)
    Owner->>ABC: root password recovery + MFA
    Admin->>Admin: tests/FND-3.sh (read-only, simulator, baseline compare)
```

## 8. Decision record

- **D1 State locking.**
  - Options: a DynamoDB lock table, or S3-native `use_lockfile`.
  - Decision: `use_lockfile` (Terraform >= 1.10).
  - Why: no extra billed resource, and DynamoDB locking is deprecated.
  - Consequence: every root needs Terraform >= 1.10. There is no lock table to tag (AC14).
- **D2 How Terraform reaches member accounts.**
  - Options:
    - (a) assume `OrganizationAccountAccessRole` from the management admin;
    - (b) the Identity Center Administrator profile for each account;
    - (c) a separate member-account root.
  - Decision: (b), in the single `organization/` root.
  - Why: (a) cannot create Offers Platform's OAAR, because it does not exist yet. (c) adds a root that AGENTS.md's layout does not list.
  - Consequences: the first apply is staged with `-target` (3.8), with the member profiles overridden to `fnd-management-admin` through `TF_VAR_*` until they work (revision 3). Running Terraform needs a live SSO session for three profiles. OAAR stays the manual recovery path and is tested by AC10.
- **D3 What counts as "carries the boundary".** Confirmed by the owner at the design gate (feedback item 2).
  - Options: the `iam:PermissionsBoundary` condition alone; resource tags; a path plus the condition.
  - Decision: path `/eng/` plus the condition where IAM supports it.
  - Why: `iam:PermissionsBoundary` is not supported for `DeleteRole`, `UpdateAssumeRolePolicy`, `TagRole` or `PassRole`. Tags can be added to unbounded roles. Paths cannot be changed after creation.
  - Consequence: open question 7 (resolved); test ARNs in 3.7.
- **D4 Keeping the boundary capped.**
  - Options: attach AWS-managed `PowerUserAccess` to the permission set and copy it into the boundary by hand; or build both from shared statements.
  - Decision: shared statements, with the core `PowerUserAccess` statement replicated inline.
  - Why: one source makes "boundary == engineering role" true by construction (req 5).
  - Consequence: the role does not follow future AWS changes to `PowerUserAccess`.
- **D5 Cost tags on the management account and the Identity Center instance** (revision 2, feedback item 4).
  - Context: the owner requires all three accounts, the Identity Center instance and the permission sets to carry the four tags, with AC16's "no plan changes" kept.
  - Options for the management account: (a) import it into `aws_organizations_account` and manage tags only; (b) a documented `aws organizations tag-resource` CLI step.
  - Options for the instance: (a) a Terraform resource; (b) a documented `aws sso-admin tag-resource` CLI step.
  - Decision: management account (a), with `ignore_changes` on every non-tag attribute, `close_on_deletion = false` and `prevent_destroy`. Instance (b), because the provider has no resource for the instance. Permission sets are already Terraform resources and take `default_tags`.
  - Why: (a) for the account keeps tags in code and drift visible in `plan`, like the member accounts. For the instance, only the CLI is available, and leaving it out of state means it cannot cause plan changes.
  - Consequences: one more import in 3.8 step 3 and two account variables. The instance tags are guarded only by AC14, not by `plan`. If the management account import shows a diff that `ignore_changes` cannot remove, fall back to option (b) for it and record that in the PR. The implementer does not drop the tag.
- **D6 Checks beyond the AC lists** (revision 2, feedback item 1).
  - Options: check only what AC5 to AC7 list; report the extras separately; count the extras towards the criterion.
  - Decision: count them (owner decision). TC27 and TC34's `CreatePolicyVersion` are firm denied checks (feedback item 3).
  - Consequence: 3.7 lists every extra sub-check and its expected result. Open questions 2 and 5 are closed.
- **D7 Pre-apply baseline for the regressions** (revision 2, for test plan TC67/TC68 and Q11).
  - Options: no baseline (compare with the README inventory); a baseline committed to the repo; a baseline the owner keeps outside the repo.
  - Decision: the owner takes a read-only JSON baseline before the invitation and keeps it in `${FND3_BASELINE_DIR:-$HOME/.fnd-3-baseline}`, outside the repo.
  - Why: the README inventory is redacted (no full key IDs or trust policies), so it cannot prove nothing changed. The repo is public, so the full baseline cannot be committed. Only the owner holds Offers Platform credentials before it joins.
  - Consequences: the test script needs the baseline directory on the machine that runs it. Its two regression lines are open question 8.
- **D8 Recovery-role deny and the ABC Bank boundary size** (revision 3, implementation escalations 1 and 2; owner decisions).
  - Recovery role:
    - Context: P's `NotAction [iam:*, organizations:*, account:*]` allow grants `sts:AssumeRole`. `OrganizationAccountAccessRole` trusts the management account root, so this does not open a path by itself, but TC49 (AC10) expects the engineering role to be denied it.
    - Options: rely on the trust policy alone; add an explicit deny.
    - Decision: explicit Deny `sts:AssumeRole` on `arn:aws:iam::<offers_platform>:role/OrganizationAccountAccessRole` in P. B-OP gets it too, because boundaries are built from the same statements (D4). Not added to ABC Bank, which grants no `sts` actions.
    - Consequence: TC49 stays as approved. Bounded Offers Platform roles also cannot assume the recovery role.
  - ABC Bank boundary size:
    - Context: B-ABC renders at 6,097 of the 6,144-character limit, with shortened statement IDs. A permissions boundary is a single managed policy and cannot be split.
    - Options: accept as is; reduce it now with exact-match action wildcards; narrow A.
    - Decision: accept as is for FND-3. Statement IDs are not part of the contract (3.4).
    - Consequence: ABC-6 must choose a fallback (for example exact-match action wildcards) before it adds permissions to the ABC Bank engineering role. Record this on the ABC-6 issue.
