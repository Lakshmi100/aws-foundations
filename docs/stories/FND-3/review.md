# Review: FND-3 AWS organization, accounts and Identity Center access

**Verdict:** APPROVE

Reviewed `git diff main...HEAD` (4 commits, 28 files) on branch
`FND-3-organization-identity-center` against `story.md` (re-synced, AC6/AC7/AC14
updated), `design.md` revision 3, `test-plan.md` (73 cases) and
`design-feedback.md` (gate rounds 1 and 2 plus the implementation escalations).
Nothing has been applied to AWS. The first apply needs the owner's manual root
steps (design 3.8), so `tests/FND-3.sh` cannot run against real accounts yet.
That is expected and is not counted as a defect here.

Checks run locally (no AWS calls):

| Check | Result |
|-------|--------|
| `make lint` (`terraform fmt -check -recursive`) | exit 0 |
| `make test` (`init -backend=false` + `validate`, bootstrap and organization) | exit 0, both roots valid (Terraform 1.14.1) |
| `bash tests/FND-3.selftest.sh` | exit 0, 53/53 PASS, stubbed `aws`/`terraform` only |
| Policy render (scratch copy of `policies.tf`, fake 12-digit IDs, data sources only, no credentials) | B-ABC 6,097 chars, B-OP 3,802, ABC inline 5,837, OP inline 3,542. Matches the figures in design revision 3 and the run log. All are under the 6,144 managed-policy and 32,768 permission-set limits |

## Design conformance

Every contract item in design sections 3.1 to 3.9 is implemented as specified.

- **3.1 Reference pattern.** Both roots have `versions.tf` (`>= 1.10, < 2.0`, `hashicorp/aws ~> 6.0`, lock files committed), `backend.tf` (bucket `aws-foundations-tfstate-lakshmi100`, keys `bootstrap/` and `organization/terraform.tfstate`, `use_lockfile = true`, `encrypt = true`, no profile, no DynamoDB), and `providers.tf` (`us-east-1`, `default_tags = var.cost_tags`). `cost_tags` defaults match AGENTS.md exactly. Every variable has a `description` and `type`, and every output has a `description`. `prevent_destroy` is set on the organization, all three accounts, the state bucket, the `Administrator` permission set and the `for_each` Administrator assignment (revision 3).
- **3.2 bootstrap.** Bucket with `force_destroy = false`, versioning `Enabled`, SSE-S3 `AES256`, all four public-access-block settings, `BucketOwnerEnforced`. The policy has (1) a TLS deny on the bucket and `bucket/*`, and (2) an `ArnNotLike aws:PrincipalArn` deny that excepts only `role/aws-reserved/sso.amazonaws.com/*AWSReservedSSO_Administrator_*` and `:root`, with the account taken from `data.aws_caller_identity`. Outputs and variables are as listed.
- **3.3 organization.**
  - Organization: `ALL`, the `cloudtrail` and `sso` principals, `SERVICE_CONTROL_POLICY`, no custom SCPs.
  - Management account: tags only, with the `ignore_changes` list, `close_on_deletion = false` and a `postcondition` on `master_account_id` (accepted deviation).
  - ABC Bank account: as specified.
  - Offers Platform account: `offers_platform_account_email` (revision 3) and `ignore_changes`.
  - Identity Center: user from variables. `display_name` is derived as "given family", and README step 1.5 tells the owner to use that value, so the import matches.
  - Permission sets: three, with `PT1H`/`PT4H`, and the Administrator description is word for word.
  - Policy attachments and assignments: `AdministratorAccess` attachment, two inline policies, five assignments (USER, no group).
  - Member accounts: two boundary policies (`EngineeringPermissionsBoundary`, path `/`) and the Offers Platform OAAR (trusts management `:root`, `max_session_duration = 3600`, `AdministratorAccess`).
  - Every member-account resource, including the role policy attachment, has the account-ID precondition. All variables and the nine outputs are present.
- **3.4 Policies.** R, G, A, P and K are built from shared locals and statement blocks, and each boundary is its engineering document plus K (D4), so the cap holds by construction. I checked the rendered B-OP:
  - 13 statements, including `DenyRecoveryRole` (`sts:AssumeRole` on Offers Platform `role/OrganizationAccountAccessRole`, D8);
  - `iam:PermissionsBoundary` conditions only on the five actions that support the key;
  - path-scoped `/eng/*` resources, plus the two DMS role names in ABC Bank only;
  - KMS use limited to `kms:ResourceAliases = alias/abc-bank-kms-key`, and `CreateGrant` also needs `GrantIsForAWSResource`;
  - no `iam:CreatePolicy`, `CreatePolicyVersion` or `DeletePolicy` granted, and edits to the boundary policy denied.

  Statement IDs are shortened, which 3.4 allows.
- **3.6 Makefile.** As specified, and needs no credentials.
- **3.8 / 3.9 README.** All of it is present:
  - step 0 baseline, written outside the repo with `chmod 700`;
  - step 1 includes the billing-access setting (accepted deviation);
  - explicit `-target` sets for steps 3 and 5, with the `TF_VAR_*` profile overrides and an instruction to unset them before the full apply;
  - the `sso-admin tag-resource` step for the instance;
  - pre-checks before the invitation and before the OAAR is created;
  - the five CLI profiles on one `sso-session fnd`;
  - Recovery (root plus MFA, then OAAR, with ready-made recovery profiles);
  - the inventory section with the redaction rules from open question 4.

I traced the targeted sets in steps 3 and 5. They pull in no member-provider resource, and `policies.tf` keeps the ABC Bank and Offers Platform statements in separate data sources. Step 3's ABC Bank inline policy therefore does not depend on the Offers Platform account, which has not been imported at that point.

Nothing extra beyond trivial additions: a `validation` on `engineering_role_path`, and `description` fields on the boundaries and the OAAR.

## Traceability

The script runs as follows. `tests/FND-3.sh` prints 17 AC lines and then REG-TC67 and REG-TC68. TC04, TC07, TC63 and TC72 are script-logic cases in `tests/FND-3.selftest.sh`. TC69, TC70 and TC71 have no result line: they are logged as PR evidence by `pr_evidence` (owner decision, gate round 2, item 5).

"Not run (AWS)" means the case needs the real accounts after the owner's first apply.

| Test-plan case | Test function | Passing |
|----------------|---------------|---------|
| TC01, TC02 | `check_ac1` / `ac1_eval` | Not run (AWS) |
| TC03 | `check_ac1` | Not run (AWS) |
| TC04 | `ac1_eval` via `FND-3.selftest.sh` | Yes (selftest) |
| TC05, TC06 | `check_ac2` / `ac2_eval` | Not run (AWS) |
| TC07 | `ac2_eval` via `FND-3.selftest.sh` | Yes (selftest) |
| TC08 | `check_ac2` | Not run (AWS) |
| TC09 | `check_ac3` | Not run (AWS) |
| TC10, TC11 | `check_ac3` (MANUAL line) | MANUAL, owner evidence in PR |
| TC12 to TC16 | `check_ac4` | Not run (AWS) |
| TC17 to TC20 | `check_ac5` | Not run (AWS) |
| TC21 to TC26 | `check_ac6` | Not run (AWS) |
| TC27 | `check_ac6` (ABC Bank) and `check_ac7` (Offers Platform) | Not run (AWS) |
| TC28 to TC34 | `check_ac7` (TC30 via `role_policies_json` + `expect_sim_multi`) | Not run (AWS) |
| TC35 to TC40 | `check_ac7b` | Not run (AWS) |
| TC41, TC42 | `check_ac8` (prints inventory, MANUAL line) | MANUAL, owner |
| TC43 to TC46 | `check_ac9` | Not run (AWS) |
| TC47 to TC49 | `check_ac10` | Not run (AWS) |
| TC50 | `check_ac11` | Not run (AWS harness), but the README Recovery section names root, MFA, `OrganizationAccountAccessRole`, ABC Bank and Offers Platform, so a static read passes |
| TC51 | `check_ac11` (MANUAL line) | MANUAL, owner |
| TC52, TC53 | `check_ac12` | Not run (AWS) |
| TC54 to TC57, TC59 to TC61 | `check_ac13` (`setup_clone`, bucket checks, simulations) | Not run (AWS) |
| TC58 | `lock_test` (from `check_ac13`) | Not run (AWS) |
| TC62 | `check_ac14` / `tags_eval` | Not run (AWS) |
| TC63 | `tags_eval` via `FND-3.selftest.sh` | Yes (selftest) |
| TC64 | `check_ac15` (+ MANUAL line) | Not run (AWS) / MANUAL |
| TC65, TC66 | `check_ac16` | TC66 local equivalent passes (`make lint`, `make test`); TC65 not run (AWS) |
| TC67 | `check_reg67` (REG-TC67) | Not run (AWS) |
| TC68 | `check_reg68` (REG-TC68) | Not run (AWS) |
| TC69 | `pr_evidence` (logged MANUAL) | MANUAL, owner |
| TC70, TC71 | `pr_evidence` (logged EVIDENCE) | Not run (AWS); TC71 static: no tracked `.tfvars` except `example.tfvars`, no state, no 12-digit IDs in `.tf`, providers pinned, region `us-east-1` |
| TC72 | `FND-3.selftest.sh` (missing profile, empty baseline) | Yes (selftest) |
| TC73 | `check_ac5` (allowed), `check_ac6`, `check_ac7` (denied) | Not run (AWS) |

Every test-plan ID TC01 to TC73 has a matching test. Every acceptance criterion AC1 to AC16 and AC7b has at least one case and its own output line. None can pass yet, because they need the real accounts (expected, see the top of this review).

I also checked every simulated expectation in `check_ac5` to `check_ac7b` and `check_ac10` against the rendered policies. Each allowed action has a matching Allow, and each denied action is either not granted or explicitly denied. Examples:
- `tag:GetResources` is allowed through `tag:Get*`;
- `billing:UpdateBillingPreferences` is denied through `billing:Update*`;
- TC38's `iam:CreateOpenIDConnectProvider` is outside B-OP;
- TC49 for Offers Platform hits the new explicit deny.

Nothing in the static read predicts a FAIL caused by the implementation.

## Test integrity

`git diff 7f35e22 HEAD -- tests/` is empty. No test was changed, deleted or skipped after the tester's commit. The implementer met the revision 3 TC49 expectation by changing the policy (the `sts:AssumeRole` deny), not the test.

## Rules (branch, trailers, scope, dependencies)

- **Branch:** `FND-3-organization-identity-center` matches `<KEY>-short-description`.
- **Trailers:** all 4 commits carry `Story: FND-3` and `Agent:` (orchestrator, tester, orchestrator, implementer), checked with `%(trailers:key=...)`. `Co-Authored-By` is in the same block, with no blank line inside it.
- **Scope:** the changed paths are `Makefile`, `README.md`, `bootstrap/`, `organization/`, `tests/FND-3*.sh` and `docs/stories/FND-3/`, which are the areas the story and AGENTS.md layout name. `.claude/`, `.github/`, `AGENTS.md`, `.gitignore` and lint config are untouched. Nothing is created in member accounts beyond what the story names: two boundary policies, the Offers Platform OAAR and its attachment, and the SSO-provisioned roles.
- **Dependencies:** new are the `hashicorp/aws` provider `~> 6.0` (lock files committed) and Terraform `>= 1.10`. Both are in the design. They must be listed in the PR (RULES "Do not add dependencies without listing them in the PR").
- **AGENTS.md boundaries:**
  - no account is deleted or closed;
  - `prevent_destroy` protects all Administrator assignments;
  - no root credentials are used (root steps are written down for the owner);
  - no real `.tfvars`, state or credentials are committed (`example.tfvars` uses `example.com` placeholders, `.gitignore` covers `*.tfvars` and state);
  - no IAM users or keys are created;
  - no NAT gateways.
- **Coding standards:**
  - fmt clean;
  - `us-east-1` everywhere;
  - no hard-coded account IDs (all come from `aws_caller_identity` or account resources);
  - providers pinned to a range;
  - test scripts use `set -euo pipefail`.
- **Cost:** only the state bucket is billed (SSE-S3, no DynamoDB, no KMS key), well under $0.50 per month. Nothing is billed by the hour.

## Must fix

None.

Before the story counts as done (owner steps, not code defects). These are the AGENTS.md and RULES definition of done:
1. The owner runs design 3.8 steps 0 to 6, then `bash tests/FND-3.sh`. The output, checked for account and key IDs, goes in the PR, with every AC line PASS or MANUAL-with-evidence, and REG-TC67 and REG-TC68 PASS.
2. The README "Offers Platform IAM inventory" tables are still `_to be filled by the owner_`. Requirement 6 and AC8 need them filled from the step 0 baseline, using the redaction rules, before merge.
3. The PR uses `.github/pull_request_template.md`. It states the monthly cost (AC15), lists the new provider dependency and attaches the MANUAL evidence (AC3, AC11, TC69).

## Suggestions

1. **Offers Platform engineering can assume same-account v1/v2 roles.** The `PowerUserCore` `NotAction` allow grants `sts:AssumeRole` on every role, and only the OAAR is explicitly denied (D8). Any existing v1/v2 role whose trust policy names the Offers Platform account root (`arn:aws:iam::<op>:root`) can be assumed by the day-to-day role, and so can its bounded roles, and that role may hold IAM or other rights beyond the engineering role. This is how AWS's `PowerUserAccess` behaves and the design accepted it. Still, when filling in the inventory, the owner should check `roles.json` for such trust policies, and the later "narrow below PowerUserAccess" story should add an `sts:AssumeRole` deny for non-`/eng/` roles.
2. **`iam:UpdateAssumeRolePolicy` on `/eng/*` has no condition.** An engineering role can make a bounded role trust an external account. The boundary caps what that role can do, but it is still a way out of the account. Consider a later condition, or an SCP denying trust of principals outside the organization (`aws:PrincipalOrgID`), when SCPs come into scope.
3. **Make the ARN partition consistent.** `bootstrap/main.tf` uses `data.aws_partition`, while `organization/` writes `arn:aws:` literals. Since FND-3 sets the reference pattern, pick one style for later roots.
4. **Keep the ABC Bank boundary headroom visible.** B-ABC is at 6,097 of 6,144 characters, which I confirmed by rendering it. Design D8 says to record the fallback requirement on the ABC-6 issue. Confirm that comment exists before closing FND-3.
5. **Possible first-run snag in the tester's simulations.** `check_ac10` (TC49) and `check_ac13` (TC57 to TC61) pass `--caller-arn arn:aws:iam::<acct>:user/fnd3-sim`, a user that does not exist, to `simulate-principal-policy` alongside a resource policy. AWS requires `CallerArn` to be an IAM user ARN in that case. If the simulator also requires the user to exist, those sub-checks report "simulation call failed" on the first live run. If that happens, it is a test fix for the tester. Do not change the policies to work around it.
6. **Guard against an untargeted early apply.** A plain `terraform apply` before step 5's import would try `CreateAccount` for Offers Platform with its existing email (AWS rejects it, but it is noisy). The README warns about this in bold. A one-line note in the step 3 code block ("do not run a plain apply until step 5") would make it harder to miss.
