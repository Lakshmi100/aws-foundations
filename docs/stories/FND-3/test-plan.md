# Test plan: FND-3 AWS organization, accounts and Identity Center access

Written from the story only, independently of the design.

All cases are checks in `tests/FND-3.sh` against the real accounts. The script
prints one PASS, FAIL or MANUAL line per acceptance criterion; a criterion is
PASS only when every case tagged with it passes. Notes that apply to many cases:

- "Simulate allowed / denied" means `aws iam simulate-principal-policy` against
  the role named, never the real call. Denied means `implicitDeny` or
  `explicitDeny`; the script records which. Where an action is conditioned on a
  permissions boundary, the case passes the boundary through the context key
  `iam:PermissionsBoundary` ("with boundary" = the story's boundary ARN in that
  account; "without" = key absent; "other boundary" = a different policy ARN).
- Role ARNs (owner's resolution of Q5, design sections 3.4 and 3.7): a bounded
  role lives under path `/eng/`. "With boundary" checks use
  `arn:aws:iam::<acct>:role/eng/fnd3-sim` plus context
  `iam:PermissionsBoundary=<boundary ARN>`. "Without boundary" checks use the
  same ARN with no context, or `role/OrganizationAccountAccessRole`. For actions
  that do not support the `iam:PermissionsBoundary` key (`iam:PassRole`,
  `iam:DeleteRole`, `iam:UpdateRole`, `iam:UpdateAssumeRolePolicy`), the path is
  what makes a role bounded, so "a role without boundary" for those actions is a
  role outside `/eng/` (`role/OrganizationAccountAccessRole` or `role/fnd3-sim`).
- "Engineering role" and "administrator role" mean the Identity Center role
  (`AWSReservedSSO_...`) that the permission set creates in that account.
- Boundary checks (AC7b) use `aws iam simulate-custom-policy` with an
  allow-everything identity policy as the policy input and the boundary as the
  permissions-boundary input, so any denial comes from the boundary itself. No
  test role is created.
- Expected account IDs, the boundary ARN and the profile names come from the
  design's contract and the untracked `.tfvars`/Terraform outputs, never from
  values written into the script.
- Things a case creates (a scratch clone, a credential report, short assume-role
  sessions, a held state lock) are removed or released by the script.

## Cases
| ID | Covers (AC #) | Type | Scenario | Expected result |
|----|---------------|------|----------|-----------------|
| TC01 | AC1 | positive | Management administrator profile: `aws organizations describe-organization`. | `FeatureSet` is `ALL`. |
| TC02 | AC1 | positive | Same call; compare `MasterAccountId` with `aws sts get-caller-identity` `Account` for the same profile, and with the management account ID from variables. | All three IDs are equal. |
| TC03 | AC1 | negative | `describe-organization` from the ABC Bank and the Offers Platform administrator profiles. | Same organization `Id` and same `MasterAccountId` as TC01; neither member account is the management account. |
| TC04 | AC1 | negative | Script logic: `FeatureSet` is `CONSOLIDATED_BILLING`, or the caller is not the management account. | AC1 prints FAIL (verify by feeding a stubbed response to the check function, not by changing AWS). |
| TC05 | AC2 | positive | `aws organizations list-accounts`. | Exactly 3 accounts; each has `State` (or legacy `Status`) `ACTIVE`. |
| TC06 | AC2 | positive | Match the 3 listed IDs to the expected management, ABC Bank and Offers Platform IDs. | Each expected ID appears once. Offers Platform shows `JoinedMethod: INVITED` and its pre-existing account ID; ABC Bank shows `JoinedMethod: CREATED`. |
| TC07 | AC2 | boundary | Script logic: 2 accounts, 4 accounts, or 3 accounts with one `SUSPENDED` / `PENDING_CLOSURE`. | AC2 prints FAIL in each case (stubbed response). |
| TC08 | AC2 | negative | `aws organizations list-handshakes-for-organization`. | The Offers Platform invitation is `ACCEPTED`; no handshake is left `OPEN`. |
| TC09 | AC3 | positive | `aws sso-admin list-instances --region us-east-1`; `aws identitystore list-users` on that instance. | One Identity Center instance, in `us-east-1`; exactly one user (the engineer). |
| TC10 | AC3 | positive (MANUAL) | Sign out of the Identity Center portal, sign in again. Repeat in a private window (new browser session). | An MFA prompt appears both times. Evidence in the PR. |
| TC11 | AC3 | boundary (MANUAL) | Console: Identity Center, Settings, Authentication, MFA. | "Every time they sign in"; allowed MFA types are authenticator app and/or security key only (no email one-time code); users without a device must register one. Screenshot in the PR. |
| TC12 | AC4 | positive | `aws sts get-caller-identity` with the administrator profile for each of the three accounts. | `Account` equals the expected ID for each; ARN is an `AWSReservedSSO_` role of the Administrator permission set. |
| TC13 | AC4 | positive | Same call with the ABC Bank engineering profile. | `Account` = ABC Bank; ARN is the ABC Bank engineering permission-set role. |
| TC14 | AC4 | positive | Same call with the Offers Platform engineering profile. | `Account` = Offers Platform; ARN is the Offers Platform engineering permission-set role. |
| TC15 | AC4 | negative | `aws configure get aws_access_key_id --profile <p>` for each of the five profiles. | Empty for all: every profile is an Identity Center (SSO) profile, no stored keys. |
| TC16 | AC4 | negative | `aws sso-admin list-account-assignments` for each permission set in each account. | ABC Bank engineering is assigned only in ABC Bank; Offers Platform engineering only in Offers Platform; neither engineering set is assigned in the management account. Administrator is assigned in all three (the last administrator assignment exists in each account). |
| TC17 | AC5 | positive | Simulate for the ABC Bank engineering role: `rds:CreateDBInstance`, `ec2:CreateSecurityGroup`, `ec2:CreateInstanceConnectEndpoint`, `ssm:StartSession`, `dms:CreateReplicationInstance`, `secretsmanager:CreateSecret`, `logs:CreateLogGroup`, `rds-db:connect`, `tag:GetResources`, `iam:ListUsers`. | All `allowed`. |
| TC18 | AC5 | positive | Simulate `iam:CreateRole` for the ABC Bank engineering role on `arn:aws:iam::<abc>:role/eng/fnd3-sim` with context `iam:PermissionsBoundary=<ABC Bank boundary ARN>`. | `allowed`. |
| TC19 | AC5 | positive | Real call with the ABC Bank engineering profile: `aws ce get-cost-and-usage` for the last 7 days (start = today minus 7, end = today, `DAILY`, `UnblendedCost`). | Exit 0 and a `ResultsByTime` array. Affected by Q12. |
| TC20 | AC5 (req 4) | positive | Simulate for the ABC Bank engineering role, beyond AC5's list but named in requirement 4: `iam:PassRole`, `iam:DeleteRole` and `iam:UpdateRole` on `role/eng/fnd3-sim`; `iam:CreateInstanceProfile` on `instance-profile/eng/fnd3-sim`; `ec2-instance-connect:OpenTunnel`; `ec2:RunInstances`, `ec2:CreateNetworkInterface`, `ec2:CreateVpcEndpoint`; `iam:GetRole`, `iam:ListRoles`. | All `allowed`. Counts towards AC5's PASS (owner, Q3). Affected by Q15. |
| TC21 | AC6 | negative | Simulate for the ABC Bank engineering role: `iam:CreateRole` without boundary, `iam:CreateUser`, `iam:CreateAccessKey`, `iam:DeleteRolePermissionsBoundary`, `organizations:LeaveOrganization`, `account:CloseAccount`, `sso:CreatePermissionSet`, `aws-portal:ModifyBilling`. | All denied. |
| TC22 | AC6 | negative | Simulate `iam:PassRole` for the ABC Bank engineering role on `role/OrganizationAccountAccessRole` and on `role/fnd3-sim` (path `/`). | Denied for both. |
| TC23 | AC6 | negative | Simulate `kms:ScheduleKeyDeletion` and `kms:PutKeyPolicy` for the ABC Bank engineering role on `abc-bank-kms-key`. | Denied. Affected by Q6 (the key does not exist yet). |
| TC24 | AC6 | boundary | Simulate `iam:CreateRole` for the ABC Bank engineering role on `role/eng/fnd3-sim` with context `iam:PermissionsBoundary=arn:aws:iam::aws:policy/AdministratorAccess` (other boundary), and with no context. | Both denied: only the story's boundary counts, even under `/eng/`. |
| TC25 | AC6 (req 4) | negative | Simulate for the ABC Bank engineering role, on `arn:aws:iam::<abc>:role/OrganizationAccountAccessRole` (no boundary, path `/`): `iam:AttachRolePolicy`, `iam:PutRolePolicy`, `iam:UpdateAssumeRolePolicy`, `iam:DeleteRole`, `iam:PutRolePermissionsBoundary` with other boundary. | All denied (requirement 4: roles are changed "only with the permissions boundary attached"). Counts towards AC6's PASS (owner, Q3). |
| TC26 | AC6 (req 4) | negative | Simulate for the ABC Bank engineering role: `kms:DisableKey`, `kms:CreateKey`, `organizations:CreateAccount`, `sso:CreateAccountAssignment`, `sso:DeletePermissionSet`, `account:PutAlternateContact`. | All denied (requirement 4 grants none of these; day-to-day roles cannot change the organization, billing or Identity Center). Counts towards AC6's PASS (owner, Q3). |
| TC27 | AC6, AC7 | boundary | Simulate for the ABC Bank engineering role and for the Offers Platform engineering role, each in its own account: `iam:CreatePolicyVersion` and `iam:DeletePolicy` on `arn:aws:iam::<acct>:policy/EngineeringPermissionsBoundary`; `iam:CreatePolicy` on a new policy ARN in that account. | All denied for both roles (owner, Q2). Any `allowed` is FAIL for the role's criterion. |
| TC28 | AC7 | positive | Simulate for the Offers Platform engineering role: `s3:ListBucket`, `glue:StartJobRun`; `iam:CreateRole` on `arn:aws:iam::<op>:role/eng/fnd3-sim` with context `iam:PermissionsBoundary=<Offers Platform boundary ARN>`; `iam:PassRole` on `role/eng/fnd3-sim`. | All `allowed`. |
| TC29 | AC7 | negative | Simulate for the Offers Platform engineering role: `iam:CreateRole` without boundary, `iam:CreateUser`, `iam:CreateAccessKey`, `iam:DeleteRolePermissionsBoundary`, `organizations:LeaveOrganization`, `account:CloseAccount`, `sso:CreatePermissionSet`, `aws-portal:ModifyBilling`, `billing:UpdateBillingPreferences`. | All denied. |
| TC30 | AC7 | negative | `simulate-custom-policy` with the Offers Platform engineering role's policies as the identity input and the Offers Platform boundary as the boundary input: `iam:CreateUser`. | Denied (a role created with the boundary cannot create users). |
| TC31 | AC7 | boundary | Simulate for the Offers Platform engineering role: `iam:CreateRole` on `role/eng/fnd3-sim` with context `iam:PermissionsBoundary=arn:aws:iam::aws:policy/AdministratorAccess` (other boundary); `iam:PassRole` on `role/OrganizationAccountAccessRole` and on `role/fnd3-sim` (path `/`). | All denied. |
| TC32 | AC7 (req 4) | positive | Simulate for the Offers Platform engineering role: `iam:GetRole`, `iam:ListRoles`, `iam:ListUsers` (IAM read-only); `iam:AttachRolePolicy`, `iam:DetachRolePolicy`, `iam:PutRolePolicy`, `iam:DeleteRolePolicy` on `role/eng/fnd3-sim` with context `iam:PermissionsBoundary=<Offers Platform boundary ARN>`; `iam:DeleteRole` on `role/eng/fnd3-sim`; `iam:CreateInstanceProfile` on `instance-profile/eng/fnd3-sim`; `ce:GetCostAndUsage`, `budgets:ViewBudget` (billing reads); `kms:CreateKey` (KMS not restricted). | All `allowed`. Counts towards AC7's PASS (owner, Q3). |
| TC33 | AC7 (req 4) | negative | Simulate for the Offers Platform engineering role on `arn:aws:iam::<op>:role/OrganizationAccountAccessRole` and on the ARN of one existing v1/v2 role, taken from the baseline `roles.json` (both path `/`, no boundary): `iam:AttachRolePolicy`, `iam:PutRolePolicy`, `iam:UpdateAssumeRolePolicy`, `iam:DeleteRole`. | All denied: a day-to-day role cannot take over the recovery role or change v1/v2 roles. Counts towards AC7's PASS (owner, Q3). A missing or unreadable baseline `roles.json` is FAIL for AC7. |
| TC34 | AC7 (req 4) | negative | Simulate for the Offers Platform engineering role: `sso:CreateAccountAssignment`, `sso:DeletePermissionSet`, `organizations:CreateAccount`, `account:PutAlternateContact`, `aws-portal:ModifyAccount`, `billing:PutContractInformation`, `iam:CreatePolicyVersion` on `arn:aws:iam::<op>:policy/EngineeringPermissionsBoundary`. | All denied, including `iam:CreatePolicyVersion` on the boundary policy (owner, Q2). Counts towards AC7's PASS (owner, Q3). |
| TC35 | AC7b | positive | Admin profile in ABC Bank and in Offers Platform: `aws iam get-policy` on the boundary ARN, then `get-policy-version` for the default version. | Policy exists in both accounts; document parses. |
| TC36 | AC7b | negative | `simulate-custom-policy` (allow-everything identity, boundary as boundary input), in each of the two accounts: `iam:CreateUser`, `iam:CreateAccessKey`, `iam:DeleteRolePermissionsBoundary`, `organizations:LeaveOrganization`, `account:CloseAccount`, `sso:CreatePermissionSet`, `aws-portal:ModifyBilling`, `iam:CreateRole` without boundary. | All denied in both accounts. |
| TC37 | AC7b | negative | Same method, ABC Bank boundary: `kms:Decrypt` on `abc-bank-kms-key`. | Denied. Affected by Q6. |
| TC38 | AC7b | negative | Same method, cap check. ABC Bank: `ec2:CreateVpc`. Offers Platform: `iam:CreateOpenIDConnectProvider` (an IAM action the Offers Platform engineering role does not have). | Denied in each account. The Offers Platform action is the tester's choice; see Q7. |
| TC39 | AC7b | positive | Same method, control cases so a deny-everything boundary cannot pass TC36 to TC38. ABC Bank: `logs:CreateLogGroup`, `rds:CreateDBInstance`, `iam:CreateRole` on `arn:aws:iam::<abc>:role/eng/fnd3-sim` with context `iam:PermissionsBoundary=<ABC Bank boundary ARN>`. Offers Platform: `s3:ListBucket`, `glue:StartJobRun`, `iam:CreateRole` on `arn:aws:iam::<op>:role/eng/fnd3-sim` with context `iam:PermissionsBoundary=<Offers Platform boundary ARN>`. | All `allowed`: the boundary lets through what the engineering role can do, and bounded roles can create bounded roles. |
| TC40 | AC7b | boundary | Same method, both accounts: `iam:PutRolePermissionsBoundary` and `iam:CreateRole` on `arn:aws:iam::<acct>:role/eng/fnd3-sim` with context `iam:PermissionsBoundary=arn:aws:iam::aws:policy/AdministratorAccess` (other boundary); `iam:CreateRole` on the same ARN with no context. | All denied (changing a boundary is denied; a bounded role cannot create an unbounded one). |
| TC41 | AC8 | positive (MANUAL) | Offers Platform admin profile: `aws iam list-users`, `aws iam list-access-keys` per user, `aws iam get-access-key-last-used` per key, the credential report, `aws iam list-roles`. Script prints these; a person compares them with `README.md`. | Every user, every key with last-used date and service, and every v1/v2 role (the roles in the baseline `roles.json`) appears in `README.md`; nothing listed is missing or extra. What is compared depends on Q4. |
| TC42 | AC8 | boundary | Same comparison for edge entries: a user with no keys, a key never used (`LastUsedDate` absent), a user with two keys, an inactive key. | Each edge entry is listed and shown as such (for example "never used"). |
| TC43 | AC9 | positive | Management and ABC Bank admin profiles: `aws iam list-users`. | Empty list in both. |
| TC44 | AC9 | negative | Management and ABC Bank: `generate-credential-report` (poll until `COMPLETE`), then `get-credential-report`. | No row, root included, has `access_key_1_active` or `access_key_2_active` = `true`. |
| TC45 | AC9 | positive | All three accounts: credential report, `<root_account>` row. | `mfa_active` = `true`; `access_key_1_active` and `access_key_2_active` = `false`. Affected by Q8. |
| TC46 | AC9 | boundary | Offers Platform credential report. | The check reads only the root row; existing IAM users there do not cause FAIL (story exception). |
| TC47 | AC10 | positive | Management admin profile: `aws sts assume-role` into `OrganizationAccountAccessRole` in ABC Bank, then `get-caller-identity` with the returned credentials. Repeat for Offers Platform. | Both succeed; caller account is the member account each time. Credentials are kept in memory only and expire. |
| TC48 | AC10 | negative | Offers Platform admin profile: `aws iam get-role --role-name OrganizationAccountAccessRole`, read its trust policy and attached policies. | Trust allows only the management account; it has no permissions boundary; it has administrator access, so it works for recovery. |
| TC49 | AC10 | negative | ABC Bank engineering and Offers Platform engineering profiles: simulate `sts:AssumeRole` on `OrganizationAccountAccessRole` in their own account, with the role's trust policy as the resource policy. | Denied: day-to-day roles cannot use the recovery role. |
| TC50 | AC11 | positive | Script checks `README.md` has a recovery section naming the management root user with MFA and `OrganizationAccountAccessRole` for both member accounts. | Section present. |
| TC51 | AC11 | positive (MANUAL) | The owner signs in as the management account root user with MFA (the agent never does). | Sign-in works and asks for MFA. Evidence in the PR. |
| TC52 | AC12 | positive | Management admin profile: `aws organizations list-aws-service-access-for-organization`. | Includes `cloudtrail.amazonaws.com` (and `sso.amazonaws.com`, which Identity Center needs). |
| TC53 | AC12 | positive | Management admin profile: `aws ce get-cost-and-usage` for the last 7 days. | Exit 0 and a `ResultsByTime` array. See Q13 on timing. |
| TC54 | AC13 | positive | `git clone` the branch into a scratch directory; in `bootstrap/` and every other root run `terraform init -input=false` and `terraform state list` with the management admin profile. Delete the clone afterwards. | Both succeed in every root; no prompts; `state list` is not empty. |
| TC55 | AC13 | positive | In the clone, check the bootstrap root's backend is S3 (the state was moved into the bucket); `git ls-files` shows no `*.tfstate`. | Bootstrap state is in the bucket; no state file is tracked. |
| TC56 | AC13 | positive | `aws s3api get-bucket-versioning`, `get-public-access-block`, `get-bucket-policy-status`, `get-bucket-encryption` on the state bucket. | Versioning `Enabled`; all four public-access-block settings `true`; `IsPublic` `false`; a default encryption rule exists. |
| TC57 | AC13 | negative | `get-bucket-policy`; then simulate `s3:GetObject` on a state object for the management admin role, with the bucket policy as resource policy and context `aws:SecureTransport=false`. | The policy has a Deny on bucket and objects when `aws:SecureTransport` is false; the simulation is denied. |
| TC58 | AC13 | negative | In one root, hold the state lock with a first Terraform process (for example `terraform console`, which holds the lock without changing anything); run `terraform apply -input=false -lock-timeout=0s` in a second process. Release the first; run `terraform plan` to confirm no lock is left. | Second apply fails with "Error acquiring the state lock"; nothing is applied; the final plan runs with no lock error. See Q9. |
| TC59 | AC13 | positive | Simulate `s3:GetObject` and `s3:PutObject` on a state object for the management admin role, with the bucket policy as resource policy. | `allowed`. |
| TC60 | AC13 | negative | Simulate `s3:GetObject` and `s3:PutObject` on a state object for the ABC Bank engineering and Offers Platform engineering roles, with the bucket policy as resource policy and the management account as resource owner. | Denied for both. The Offers Platform role's `PowerUserAccess` allows S3 in general, so this proves the bucket policy holds. |
| TC61 | AC13 (req 10) | boundary | Same as TC60 for the ABC Bank and Offers Platform administrator roles; and `simulate-custom-policy` with an allow-everything identity policy, the bucket policy and a caller ARN of another (hypothetical) role in the management account. | Denied in all cases: only the management administrator role (and root) can read or write state. |
| TC62 | AC14 | positive | For each taggable resource the story creates or manages, read its tags: state bucket (`get-bucket-tagging`); a lock table only if one exists (DynamoDB `list-tags-of-resource`; skipped, not FAIL, if the state uses no table); all three accounts, management included, with `organizations list-tags-for-resource --resource-id <account ID>` for the management, ABC Bank and Offers Platform account IDs; the Identity Center instance and every permission set (`sso-admin list-tags-for-resource`); boundary policies (`iam list-policy-tags`); Offers Platform `OrganizationAccountAccessRole` (`iam list-role-tags`). The list is cross-checked against `terraform state list`. | Each has `data-product=aws-foundations`, `environment=shared`, `owner=Lakshmi100`, `cost-center=offers-platform-portfolio`. A missing management account tag is FAIL (owner, Q10). |
| TC63 | AC14 | negative | Script logic: a resource missing one tag, a wrong value (`environment=prod`), a key with different case (`Owner`). | AC14 prints FAIL in each case (stubbed response). |
| TC64 | AC15 | positive (MANUAL) | Script prints MANUAL: check the PR states the monthly cost. Supporting check: the state bucket's encryption is SSE-S3 or the AWS-managed key, not a customer-managed KMS key ($1 per month alone). | PR states a cost under $0.50 per month; no customer-managed key or hourly-billed resource is in any root's state. |
| TC65 | AC16 | positive | In every root: `terraform plan -detailed-exitcode -input=false`. | Exit code 0 (no changes). Exit 2 or 1 prints FAIL. |
| TC66 | AC16 | positive | `terraform fmt -check -recursive`, `terraform validate` in every root, `make test`, `make lint`. | All exit 0; the `Makefile` exists with both targets. |
| TC67 | – | regression | Offers Platform: compare live `aws iam list-users` and `list-access-keys` per user (UserName, AccessKeyId, Status) with the pre-invitation baseline `users.json` and `access-keys.json` in `${FND3_BASELINE_DIR:-$HOME/.fnd-3-baseline}` (outside the repo). Printed as line `REG-TC67`. | Same users; same keys; every key active before is still active. Nothing deactivated or deleted. Baseline directory or either file missing or unreadable is FAIL, never skipped. |
| TC68 | – | regression | Offers Platform: for every role in the baseline `roles.json` in `${FND3_BASELINE_DIR:-$HOME/.fnd-3-baseline}` (these define the existing v1/v2 roles), live `get-role`, `list-attached-role-policies`, `list-role-policies` and each `get-role-policy`, compared with the baseline. Printed as line `REG-TC68`. | Every baseline role still exists; no permissions boundary attached; path, trust policy, attached and inline policies unchanged. Baseline missing or unreadable is FAIL, never skipped. |
| TC69 | – | regression (MANUAL) | The owner runs a read command with an existing v1/v2 laptop profile (for example `aws sts get-caller-identity` and an `aws s3 ls` the v1/v2 tools use). | Still works after the account joined the organization. |
| TC70 | – | regression | `aws organizations list-policies --filter SERVICE_CONTROL_POLICY`, `list-policies-for-target` on the root and each account; `list-organizational-units-for-parent` on the root. | If SCPs are enabled, only `FullAWSAccess` exists and is attached; no OUs exist (out of scope). |
| TC71 | – | regression | Repo hygiene: `git ls-files` shows no `*.tfvars` other than `example.tfvars`, no state, no credentials; no 12-digit account IDs in `.tf` files outside variable defaults or `.tfvars`; providers pinned to a version range; region `us-east-1`. | All hold. |
| TC72 | – | regression | Run `tests/FND-3.sh` itself with one profile deliberately missing. | Script uses `set -euo pipefail`, still prints exactly one PASS, FAIL or MANUAL line for each of AC1 to AC16 and AC7b (17 lines whose ID starts with `AC`, in order AC1 to AC16 with AC7b after AC7), followed by exactly two regression lines `REG-TC67` and `REG-TC68` (PASS or FAIL); no other result lines. Marks the affected lines FAIL rather than aborting, exits 1 if any AC or REG line is FAIL, and leaves nothing behind (no clone, no held lock). A second run with the baseline directory pointed at an empty path shows `REG-TC67` and `REG-TC68` as FAIL and exit 1. |
| TC73 | AC5, AC6, AC7 | boundary | Path rule. Simulate `iam:CreateRole` for each engineering role in its own account on `arn:aws:iam::<acct>:role/fnd3-sim` (path `/`) with context `iam:PermissionsBoundary=<that account's boundary ARN>`. Then simulate `iam:CreateRole` with the same boundary context on `role/dms-vpc-role` and `role/dms-cloudwatch-logs-role`: for the ABC Bank engineering role in ABC Bank, and for the Offers Platform engineering role in Offers Platform. Also, ABC Bank engineering on the two DMS role names with no context. | `role/fnd3-sim` denied for both roles even with the boundary (AC6, AC7). ABC Bank: both DMS role names `allowed` with the boundary (AC5), denied without it (AC6). Offers Platform: both DMS role names denied even with the boundary (AC7). |

Types: positive, negative, boundary, regression.

## Acceptance criteria coverage
| AC # | Criterion | Cases |
|------|-----------|-------|
| AC1 | Organization has all features, this account is management | TC01, TC02, TC03, TC04 |
| AC2 | Exactly three accounts, all active | TC05, TC06, TC07, TC08 |
| AC3 | MFA at every portal sign-in (MANUAL) | TC09, TC10, TC11 |
| AC4 | Each role's profile reaches the expected account | TC12, TC13, TC14, TC15, TC16 |
| AC5 | ABC Bank engineering allowed actions, real Cost Explorer call | TC17, TC18, TC19, TC20, TC73 |
| AC6 | ABC Bank engineering denied actions | TC21, TC22, TC23, TC24, TC25, TC26, TC27, TC73 |
| AC7 | Offers Platform engineering allowed and denied actions | TC27, TC28, TC29, TC30, TC31, TC32, TC33, TC34, TC73 |
| AC7b | Permissions boundary exists and denies, in both accounts | TC35, TC36, TC37, TC38, TC39, TC40 |
| AC8 | Offers Platform IAM inventory in `README.md` (MANUAL) | TC41, TC42 |
| AC9 | No IAM users or active keys; root MFA, no root keys | TC43, TC44, TC45, TC46 |
| AC10 | Assume `OrganizationAccountAccessRole` into both member accounts | TC47, TC48, TC49 |
| AC11 | Recovery steps in `README.md`; root sign-in (MANUAL) | TC50, TC51 |
| AC12 | CloudTrail trusted access; Cost Explorer enabled | TC52, TC53 |
| AC13 | State bucket: init, versioning, public block, encryption, TLS, locking, access | TC54, TC55, TC56, TC57, TC58, TC59, TC60, TC61 |
| AC14 | Four cost tags on every taggable resource | TC62, TC63 |
| AC15 | PR states monthly cost under $0.50 (MANUAL) | TC64 |
| AC16 | No plan changes; fmt and validate pass | TC65, TC66 |
| – | Regression: v1/v2 users, keys, roles, credentials; default SCP; repo hygiene; script behaviour | TC67, TC68, TC69, TC70, TC71, TC72 |

## Questions for the story

Questions from the story review. Q2 and Q3 were resolved by the owner at the
design gate (`design-feedback.md`, 2026-11-01); the rest are still open. The
plan does not answer open questions; it notes where they change a case.

- **Q1 (story review): first-apply credentials.** Who runs the first `bootstrap/` and `organization/` applies, with what credentials? Affects TC54 and TC58 (which profile can run Terraform), and TC43/TC44: if a temporary IAM user is used, AC9 must be checked only after it is deleted.
- **Q2 (story review): customer-managed policies and the boundary policy itself. Resolved.** Owner (design feedback item 3): neither engineering role gets `iam:CreatePolicy`, `iam:CreatePolicyVersion` or `iam:DeletePolicy`; edits to the boundary policy are explicitly denied. TC27 and the `iam:CreatePolicyVersion` part of TC34 are firm denied checks.
- **Q3 (story review): checks beyond AC6/AC7's text.** TC20, TC25, TC26, TC32, TC33 and TC34 test what requirement 4 states (IAM read-only, policy changes on bounded roles, billing reads, no changes to unbounded roles such as `OrganizationAccountAccessRole`) but go beyond the action lists in AC5 to AC7. **Resolved.** Owner (design feedback item 1): they count towards their criterion's PASS.
- **Q4 (story review): what the public `README.md` inventory may contain.** TC41 and TC42 compare live IAM data with `README.md`. Without an answer the tester does not know whether to compare user names, key IDs (full, last 4, none) and role names or ARNs, or whether the inventory lives in an untracked file.

Questions raised by this plan:

- **Q5: "a role with / without the boundary" for `iam:PassRole`. Resolved.** Owner (design feedback item 2): bounded roles live under path `/eng/`, plus the `iam:PermissionsBoundary` condition where IAM supports it. Cases use `role/eng/fnd3-sim` (with boundary context where supported) and, for "without", the same ARN without context or a role outside `/eng/`. TC73 covers roles outside `/eng/` and the ABC Bank DMS role-name exception.
- **Q6: `abc-bank-kms-key` does not exist yet** (created by ABC-4). AC6 and AC7b still require denials on it. What resource ARN or context (for example `kms:ResourceAliases`) do TC23 and TC37 simulate against? If the deny is scoped to a key ARN, these cases cannot run until ABC-4.
- **Q7: cap check example for Offers Platform.** AC7b gives `ec2:CreateVpc` for ABC Bank only. TC38 uses `iam:CreateOpenIDConnectProvider` for Offers Platform. Is that acceptable?
- **Q8: centralized root access management.** If member-account root credentials are removed instead of given MFA, the credential report may show `mfa_active=false` for those roots. Does TC45 pass in that case?
- **Q9: lock test.** AC13 says "a second concurrent `terraform apply`". TC58 holds the lock with a non-changing process instead of a real first apply, so nothing is changed. Is that acceptable as evidence?
- **Q10: which resources count for AC14. Resolved.** Owner (design feedback item 4): all three accounts, management included, carry the four cost tags; the Identity Center instance and permission sets are in scope; a lock table only if one exists. TC62 checks all of these.
- **Q11: baseline for the regressions. Resolved by the design (revision 2, D7), pending owner confirmation at the gate.** The owner takes a read-only JSON snapshot (`users.json`, `access-keys.json`, `roles.json`) of the Offers Platform users, keys and roles before the invitation is sent, stored in `${FND3_BASELINE_DIR:-$HOME/.fnd-3-baseline}` outside the repo and never committed. The roles in `roles.json` define "existing v1/v2 roles" for TC33, TC41 and TC68. A missing baseline is FAIL.
- **Q12: Cost Explorer from a member account.** TC19's real call from ABC Bank may need a Cost Management preference set in the management account. It is not among requirement 9's manual steps. If the call fails for that reason, is AC5 a FAIL, or is a manual step missing?
- **Q13: Cost Explorer timing.** After Cost Explorer is enabled, data can take up to a day to appear. How long after enablement may TC19 and TC53 be run before an error counts as FAIL?
- **Q14: MFA settings have no read API.** AC3 is MANUAL, and the "authenticator app or security key" part of requirement 3 has no criterion. TC11 checks it by screenshot. Is that enough?
- **Q15: access path.** Requirement 4 says Session Manager "or" EC2 Instance Connect Endpoint tunnels; AC5 checks `ssm:StartSession` and `ec2:CreateInstanceConnectEndpoint`. TC20 also checks `ec2-instance-connect:OpenTunnel`. Must the role allow both paths?
