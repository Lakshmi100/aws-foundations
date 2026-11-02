Source: https://github.com/Lakshmi100/aws-foundations/issues/3

# AWS organization, accounts and Identity Center access

**Story key:** `FND-3` · **Draft ID:** FND-1 · **Readiness:** 87/100 READY ([story review](https://github.com/Lakshmi100/offers-platform-workspace/blob/main/stories/drafts/FND-1.story-review.md), [draft](https://github.com/Lakshmi100/offers-platform-workspace/blob/main/stories/drafts/FND-1.md))

**Approval:** review this story and comment with changes. To sign off, add the `approved` label and remove `needs-approval`; `/story` runs only on approved stories.

---

## User story

**As** the engineer building the Offers Platform,
**I want** the three AWS accounts in one organization, with sign-in through IAM Identity Center and no IAM users in the new accounts,
**so that** every later story has an account to build in and a way for people and tools to get into it without long-lived keys.

## Context

Roadmap decision: three accounts, "Management + Shared Services" (new), "ABC Bank" (new) and "Offers Platform" (existing), and "human access through IAM Identity Center only; no IAM users" (`docs/00-roadmap.md` §1, Phase 1 in §4). Spike 1 was not carried out, so nothing exists yet except the Offers Platform account. That account has IAM users and access keys in use today, most likely by laptop tools (AWS CLI, Terraform, local Airflow, Spark) reading keys from `~/.aws`. The v1/v2 code itself holds no keys; its Terraform creates IAM roles (for example Snowflake's S3 access role). The v1/v2 code (`customer-spend-analytics`), its IAM roles and the credentials its tools use stay as they are in this story; the Offers Platform account gets fresh roles created here, for new work.

## Requirements

1. **Organization:** an AWS Organization with **all features** enabled (required by Identity Center and by FND-4 (#4)'s organization trail), with the Management + Shared Services account as its management account and consolidated billing.
2. **Accounts:** the ABC Bank account is created in the organization; the existing Offers Platform account is invited and joins it.
3. **Sign-in:** IAM Identity Center is enabled with one user for the engineer. MFA is required **at every sign-in**, using an authenticator app or security key.
4. **Roles (Identity Center permission sets):**
   - **Administrator**, in each of the three accounts: for setup, recovery and applying long-lived foundations (ABC-3 (Lakshmi100/abc-bank#3), ABC-4 (Lakshmi100/abc-bank#4), ABC-5 (Lakshmi100/abc-bank#5) and FND-4 (#4)). Not for day-to-day work.
   - **ABC Bank engineering**, in the ABC Bank account, for session work from ABC-6 (Lakshmi100/abc-bank#6) on. It can:
     - run Terraform for session roots: RDS, EC2 (instances, security groups, network interfaces, interface endpoints, EC2 Instance Connect endpoints), DMS, Secrets Manager, CloudWatch Logs;
     - open the laptop-to-private-subnet access path (Systems Manager Session Manager sessions, or EC2 Instance Connect Endpoint tunnels);
     - create, update and delete IAM roles and instance profiles **only with the permissions boundary below attached**, and pass only such roles (`iam:PassRole`);
     - use (not create, delete, disable or change the policy of) the ABC Bank KMS key, alias `abc-bank-kms-key`;
     - read and write the ABC Bank Terraform state bucket, `abc-bank-offers-platform`;
     - connect to RDS with IAM database authentication (`rds-db:connect`);
     - read Cost Explorer for its account, the Resource Groups Tagging API, and IAM in read-only form (for example `iam:ListUsers`).
   - **Offers Platform engineering**, in the Offers Platform account, for new day-to-day work in that account. It is a fresh role: the v1/v2 pipeline and its laptop tools keep their current credentials until a later story. Based on AWS's `PowerUserAccess` (every service except IAM, Organizations and account management), plus IAM in read-only form, plus creating, updating and deleting IAM roles and instance profiles **only with the permissions boundary attached**, and passing only such roles. Updating includes attaching, detaching, adding and removing policies (managed and inline) on roles that carry the boundary. Because `PowerUserAccess` itself allows Identity Center and billing actions, the role also carries explicit denies for Identity Center changes, billing changes and account changes. Billing and cost **reads** are not denied (for example `ce:GetCostAndUsage` and `budgets:ViewBudget`). KMS is not restricted: the ABC Bank key is in another account, and v1/v2 manages its own keys.
5. **Permissions boundary** (in the ABC Bank and Offers Platform accounts): any role created by an engineering role carries it. The boundary is **capped to the engineering role's own permissions** in that account: a role that carries it can never do more than the ABC Bank engineering role (in ABC Bank) or the Offers Platform engineering role (in Offers Platform), so any role it creates must carry the same boundary too. On top of that, it denies creating IAM users or access keys; any Organizations, billing, account or Identity Center change; changing or removing permissions boundaries; and using the ABC Bank KMS key (`abc-bank-kms-key`, the same key as in requirement 4) directly (AWS services still use it through grants, ABC-4 (Lakshmi100/abc-bank#4)).
6. **IAM users:**
   - **Management + Shared Services and ABC Bank:** no IAM users and no access keys.
   - **Offers Platform: inventory only.** List every IAM user and access key, with when each key was last used and for what (IAM credential report and access-key last-used data), and record them in `README.md`. Nothing is deactivated or deleted in this story: the v1/v2 tools still use these keys. Replacing and removing them is a later story.
   - **Existing v1/v2 IAM roles** in the Offers Platform account are not changed (no permissions boundary attached). They are listed in `README.md` so the later story knows what exists.
7. **Recovery path:** if Identity Center or a permission set breaks, the owner can still get in:
   - management account: the root user, with MFA, used only for recovery;
   - member accounts: from the management account's administrator role, assume `OrganizationAccountAccessRole` in each member account. AWS creates it in accounts made inside the organization; for the invited Offers Platform account it is created by this story.
   - The steps are written in `README.md`. Root users of the member accounts have MFA and no access keys.
8. **Organization services for later stories:** CloudTrail trusted access is enabled (FND-4 (#4)'s organization trail), and **Cost Explorer is enabled** in the management account (FND-4 (#4)'s cost-allocation tags; ABC-6 (Lakshmi100/abc-bank#6)'s cost check).
9. **Manual steps:** everything is defined in Terraform in `aws-foundations`, except steps AWS only allows by hand. `README.md` lists them for the owner: signing up the management account and setting its root MFA; enabling Identity Center and its MFA setting, if the API doesn't allow it; accepting the invitation from inside the Offers Platform account; enabling Cost Explorer; setting MFA on the member accounts' root users.
10. **State:** Terraform state for `aws-foundations` is stored in S3 in the management account, with locking and version history, created by `bootstrap/`. The bootstrap's own state is moved into that bucket once it exists. The bucket is never public, refuses requests without TLS, is encrypted at rest, and only the management account's administrator role (and its root user, for recovery) can read or write it.

## Constraints

| Area | Constraint |
|---|---|
| Access and lock-out | Recovery path as in requirement 7, checked by AC10 and AC11 before the story is done. |
| Least privilege | Administrator roles are for setup and recovery only. Day-to-day work uses the two engineering roles (requirement 4), and roles they create are held by the permissions boundary (requirement 5). |
| No IAM users or long-lived keys | None in the Management + Shared Services and ABC Bank accounts. **Exception:** the Offers Platform account's existing IAM users and keys stay until a later story, because the v1/v2 tools depend on them and v1/v2 is out of scope; this story only inventories them (requirement 6). Root users in all three accounts have MFA and no access keys. |
| Personal data | The engineer's name and email, and the account emails, end up in Terraform state; the state bucket's access rules (requirement 10) protect them. The values themselves go in the untracked `.tfvars` file. |
| Cost | Long-lived. The only billable resource is the state bucket, under $0.50 per month. Organizations, Identity Center and the role assignments are free. |
| Tagging | Taggable resources carry the four cost tags with the values in `AGENTS.md`. |
| Audit | No organization trail yet (FND-4 (#4)). Trusted access for CloudTrail is enabled here (requirement 8). |
| Effect on member accounts | **Offers Platform:** billing moves to the management account; AWS's default "allow everything" service control policy is attached, so nothing is restricted; its IAM users and keys are inventoried but not changed, and its existing v1/v2 IAM roles are not changed (requirement 6); `OrganizationAccountAccessRole`, the fresh engineering role and the permissions boundary are added. **ABC Bank:** created new. |
| Region | Identity Center and Terraform use `us-east-1`. |

## Acceptance criteria

Every criterion runs against the real accounts. Checks that something is denied use `aws iam simulate-principal-policy`, never the real call.

- [ ] **AC1** From the management account, `aws organizations describe-organization` shows `FeatureSet: ALL` and this account as the management account.
- [ ] **AC2** `aws organizations list-accounts` lists exactly the three accounts, all `ACTIVE`.
- [ ] **AC3** Signing in through the Identity Center portal asks for MFA every time (MANUAL: sign out, sign in, confirm the MFA prompt).
- [ ] **AC4** With each role's CLI profile, `aws sts get-caller-identity` returns the expected account: administrator in all three accounts, ABC Bank engineering, and Offers Platform engineering.
- [ ] **AC5** For the ABC Bank engineering role, the policy simulator shows **allowed**: `rds:CreateDBInstance`, `ec2:CreateSecurityGroup`, `ec2:CreateInstanceConnectEndpoint`, `ssm:StartSession`, `dms:CreateReplicationInstance`, `secretsmanager:CreateSecret`, `logs:CreateLogGroup`, `rds-db:connect`, `tag:GetResources`, `iam:ListUsers`, and `iam:CreateRole` *with* the permissions boundary. A real `aws ce get-cost-and-usage` for the last 7 days succeeds.
- [ ] **AC6** For the ABC Bank engineering role, the policy simulator shows **denied**: `iam:CreateRole` *without* the permissions boundary, `iam:PassRole` for a role without it, `iam:CreateUser`, `iam:CreateAccessKey`, `iam:DeleteRolePermissionsBoundary`, `organizations:LeaveOrganization`, `account:CloseAccount`, `sso:CreatePermissionSet`, `aws-portal:ModifyBilling`, `kms:ScheduleKeyDeletion`, `kms:PutKeyPolicy`. Also **denied**: changing `OrganizationAccountAccessRole` (`iam:AttachRolePolicy`, `iam:PutRolePolicy`, `iam:UpdateAssumeRolePolicy`, `iam:DeleteRole`); `iam:CreatePolicy`, and `iam:CreatePolicyVersion` and `iam:DeletePolicy` on the boundary policy; `kms:CreateKey`, `kms:DisableKey`, `organizations:CreateAccount`, `sso:CreateAccountAssignment`, `account:PutAlternateContact`. Also **allowed**: `iam:PassRole`, `iam:DeleteRole` and `iam:UpdateRole` on a role with the boundary, `iam:CreateInstanceProfile`, `iam:GetRole`, `ec2-instance-connect:OpenTunnel`.
- [ ] **AC7** For the Offers Platform engineering role, the policy simulator shows `s3:ListBucket`, `glue:StartJobRun`, `iam:CreateRole` *with* the boundary and `iam:PassRole` for a role with the boundary **allowed**; and **denied** for `iam:CreateRole` without the boundary, `iam:CreateUser`, `iam:CreateAccessKey`, `iam:DeleteRolePermissionsBoundary`, `organizations:LeaveOrganization`, `account:CloseAccount`, `sso:CreatePermissionSet`, `aws-portal:ModifyBilling` and `billing:UpdateBillingPreferences`. For a role created with the boundary, `iam:CreateUser` is **denied**. Also **allowed**: IAM reads (`iam:GetRole`, `iam:ListRoles`, `iam:ListUsers`); attaching, detaching, adding and removing policies on a role with the boundary; `ce:GetCostAndUsage` and `budgets:ViewBudget`. Also **denied**: changing `OrganizationAccountAccessRole` or an existing v1/v2 role (`iam:AttachRolePolicy`, `iam:PutRolePolicy`, `iam:UpdateAssumeRolePolicy`, `iam:DeleteRole`); `iam:CreatePolicy`, and `iam:CreatePolicyVersion` and `iam:DeletePolicy` on the boundary policy; `sso:CreateAccountAssignment`, `organizations:CreateAccount`, `account:PutAlternateContact`.
- [ ] **AC7b** The permissions boundary exists in both the ABC Bank and the Offers Platform accounts (`aws iam get-policy`). For a role that carries it in each account (checked with `aws iam simulate-custom-policy`, passing the boundary as the permissions-boundary input, so no test role is created), the simulator shows **denied** for: `iam:CreateUser`, `iam:CreateAccessKey`, `iam:DeleteRolePermissionsBoundary`, `organizations:LeaveOrganization`, `account:CloseAccount`, `sso:CreatePermissionSet`, `aws-portal:ModifyBilling`, and `iam:CreateRole` *without* the boundary; in the ABC Bank account also direct use of `abc-bank-kms-key` (`kms:Decrypt`); and, because the boundary is capped to the engineering role's own permissions, an action that engineering role cannot do (in ABC Bank, an EC2 action outside requirement 4's list, for example `ec2:CreateVpc`).
- [ ] **AC8** (MANUAL) `README.md` lists every IAM user and access key in the Offers Platform account, with when each key was last used and for what, and every existing v1/v2 IAM role; the list matches `aws iam list-users`, `aws iam list-access-keys` and `aws iam list-roles` in that account.
- [ ] **AC9** In the Management + Shared Services and ABC Bank accounts, `aws iam list-users` returns no users and the IAM credential report shows no active access keys. In all three accounts the credential report shows MFA on the root user and no root access keys.
- [ ] **AC10** From the management account's administrator role, `aws sts assume-role` into `OrganizationAccountAccessRole` succeeds for both member accounts.
- [ ] **AC11** `README.md` has the recovery steps (MANUAL: confirm root sign-in with MFA works for the management account; AC10 covers the member-account path).
- [ ] **AC12** `aws organizations list-aws-service-access-for-organization` includes `cloudtrail.amazonaws.com`, and `aws ce get-cost-and-usage` in the management account succeeds (Cost Explorer enabled).
- [ ] **AC13** State: from a fresh clone, `terraform init` and `terraform state list` work in `bootstrap/` and every other root; the bucket has versioning on, all public access blocked, encryption at rest and a TLS-only policy; a second concurrent `terraform apply` fails with a state-lock error; the policy simulator shows `s3:GetObject` on state allowed for the administrator role and denied for the ABC Bank and Offers Platform engineering roles.
- [ ] **AC14** The state bucket, every other taggable resource this story creates, **all three accounts (including the management account), the Identity Center instance and the permission sets** have the four cost tags with the values in `AGENTS.md`.
- [ ] **AC15** (MANUAL) The PR states the expected monthly cost, under $0.50.
- [ ] **AC16** `terraform plan` in every `aws-foundations` root shows no changes after apply; `terraform fmt -check` and `terraform validate` pass.

## Out of scope

- Checking the ABC Bank engineering role's use of the KMS key and the state bucket: those resources are created later and checked by ABC-4 (Lakshmi100/abc-bank#4) AC3 and ABC-3 (Lakshmi100/abc-bank#3) AC7a
- Organizational units, and service control policies other than AWS's default
- A tag policy (a later `aws-foundations` story; until then each story's criteria check tags)
- CloudTrail organization trail, budgets, anomaly detection, cost-allocation tags (FND-4 (#4))
- Terraform state storage in the member accounts (ABC-3 (Lakshmi100/abc-bank#3) for ABC Bank; Offers Platform later)
- Narrowing the Offers Platform engineering role below `PowerUserAccess` (a later story, once the v3 platform's needs are known)
- GitHub Actions OIDC roles
- Any change to `customer-spend-analytics` (the v1/v2 code, its Terraform, its IAM roles) or to the credentials its tools use
- Attaching the permissions boundary to existing v1/v2 IAM roles
- Replacing and removing the Offers Platform account's IAM users and access keys, and moving the v1/v2 tools to Identity Center (a later story)

## Depends on

- None in other stories. The manual steps in requirement 9 are part of this story and done by the owner.

## Decisions

- Nov 1, 2026: Spike 1 was not carried out, so this story creates everything.
- Nov 1, 2026: management-account Terraform lives in `aws-foundations`.
- Nov 1, 2026: ~~the Offers Platform account's IAM users are replaced and removed in this story, not exempted.~~ Superseded below.
- Nov 1, 2026: the engineer connects to RDS with IAM database authentication through the ABC Bank engineering role.
- Nov 1, 2026: the Offers Platform account gets a day-to-day engineering role based on `PowerUserAccess`, with IAM role creation held by a permissions boundary. ~~Existing v1/v2 roles get the boundary too.~~ Superseded below.
- Nov 1, 2026 (after story review round 1): the Offers Platform account gets fresh IAM roles for new work; `customer-spend-analytics` (v1/v2) is not reused or changed. Its IAM users and keys are only inventoried here; removing them is a later story.
- Nov 1, 2026 (after story review round 1): the permissions boundary is capped to the creating engineering role's own permissions. The ABC Bank KMS key's alias is `abc-bank-kms-key` and the ABC Bank state bucket is `abc-bank-offers-platform`; the name was checked as free on Nov 1, 2026, but S3 names are global, so ABC-3 confirms it when it creates the bucket; ABC-4 (Lakshmi100/abc-bank#4) and ABC-3 (Lakshmi100/abc-bank#3) create them under these names. The Offers Platform engineering role gets IAM read-only access, may change policies on bounded roles, and keeps billing and cost reads. The manual steps in requirement 9 are checked by the owner by hand; they have no acceptance criterion.
- Nov 2, 2026 (design gate): AC6 and AC7 add the extra allowed and denied checks; AC14 covers all three accounts, the Identity Center instance and the permission sets. Full record: `docs/stories/FND-3/design-feedback.md`.
- **Proposed defaults, for the approver to confirm:** MFA at every sign-in with an authenticator app or security key.

## Open questions

None.





