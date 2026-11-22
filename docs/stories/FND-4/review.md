# Review: FND-4 Cost and audit guardrails for the organization

**Verdict:** APPROVE

Reviewed `main...HEAD` on `FND-4-cost-audit-guardrails` (commits 83c2434,
95b43d4, 3ca3ab9, f14ceb9, 4a5fd97) against story.md, story-review.md,
design.md (Revision 2), test-plan.md (Revision 2), design-feedback.md,
`AGENTS.md` and `.claude/factory/RULES.md`. Where the two rule files touch
the same matter, `AGENTS.md` was followed for repo matters (commands,
coding standards, boundaries) and RULES.md for pipeline matters (branch,
trailers, workspace).

Commands run by the reviewer (read-only, `AWS_PROFILE=fnd-management-admin`):

| Command | Result |
|---------|--------|
| `make test` | bootstrap, organization, guardrails: "The configuration is valid." exit 0 |
| `make lint` | `terraform fmt -check -recursive` exit 0 |
| `bash tests/FND-4.selftest.sh` | 288 PASS, 0 FAIL, exit 0 |
| `terraform -chdir=guardrails plan -detailed-exitcode -lock=false` | "No changes. Your infrastructure matches the configuration." |
| `terraform -chdir=guardrails state list` | 13 managed resources + 4 data sources, all in the management account root; no member-account resources |

`tests/FND-4.sh` was not run by the reviewer (orchestrator re-run in progress).

## Design conformance

Every contract item in design.md section 3 is implemented as specified:

- **3.1 Root pattern:** `versions.tf` (`>= 1.10, < 2.0`, `hashicorp/aws ~> 6.0`), lock file committed, `backend.tf` key `guardrails/terraform.tfstate` with no profile, one default provider in `us-east-1` with `default_tags = var.cost_tags`, no member aliases. Account, organization and partition come from data sources. `prevent_destroy` on `aws_s3_bucket.trail` and `aws_cloudtrail.organization`.
- **3.2 Variables:** all twelve present with the specified types and defaults; `alert_email` is `sensitive` and required; `posture` validation accepts exactly `lean`/`working`; `budget_limit_override_usd` nullable with `null or > 0` validation; every variable has a description. `local.budget_limit = coalesce(...)` exactly as specified. `example.tfvars` uses `alerts@example.com` with the rest commented out.
- **3.3 Outputs:** all nine outputs present and described; none exposes `alert_email`.
- **3.4 Budget:** COST / MONTHLY, `format("%.2f", ...)`, USD, no cost filter, default (unblended) cost types, three ACTUAL / PERCENTAGE / GREATER_THAN notifications at 50/80/100 to `[var.alert_email]`. Tags through `default_tags` (AC12 passed live, so no explicit `tags` needed).
- **3.5 Anomaly:** DIMENSIONAL/SERVICE monitor; DAILY subscription on that monitor only, one EMAIL subscriber, `ANOMALY_TOTAL_IMPACT_ABSOLUTE` `GREATER_THAN_OR_EQUAL` `"10"`. Default monitor and subscription imported per story decision Q1 (README step 3).
- **3.6 Cost-allocation tags:** `for_each = toset(keys(var.cost_tags))`, `Active`.
- **3.7 Trail and bucket:** versioning Enabled, AES256, all four public-access-block flags, BucketOwnerEnforced, two whole-bucket lifecycle rules (90 / 30 / 7-day multipart abort; separate expired-delete-marker rule, D4). Bucket policy has exactly the three specified statements with the specified conditions, `depends_on` the public access block; trail ARN built from parts. Trail: organization, multi-region, global events, validation, logging, one `All` management event selector, no CWL/SNS/KMS/Insights, `depends_on` the policy.
- **3.8 / 3.9:** tests and README procedure (I1 baseline, tag pre-check, import, posture switch, AC3 owner procedure, Offers Platform inventory and Q3 removal steps 1-5 with placeholders) are present.

**Deviations from the design, judged:**

1. **`anomaly_subscription_name` variable (default `aws-foundations-daily-summary`).** Acceptable. Design 3.5 step 2 already anticipated this: "Its `name` changes to the contract name only if the API allows an in-place change; otherwise `name` is set to the existing name." The API does not rename a subscription in place, so renaming the imported `Default-Services-Subscription` would replace it. Making the name a variable mirrors the design's own `anomaly_monitor_name` treatment, keeps the contract default as the design's literal, and is documented in README step 3 and `example.tfvars`. It is an addition to the 3.2 table and should be listed in the PR.
2. **`guardrails/main.tf` (data sources and locals).** Acceptable. Design 3.1 requires `aws_caller_identity` and `aws_organizations_organization` data sources and 3.2 requires `local.budget_limit`; the design just did not name the file that holds them. The file mirrors `organization/main.tf`. The extra `aws_partition` data source implements the design's `<partition>` placeholder in the trail ARN (3.7) rather than hard-coding `aws`. No new behaviour.

Nothing else extra was found.

## Traceability

Every test-plan case ID TC01 to TC74 is referenced in `tests/FND-4.sh` and/or `tests/FND-4.selftest.sh`. Stubbed-response cases (TC04, TC16, TC18, TC25, TC33, TC39, TC58, TC63, TC74) live in the self-test. "Passing" is the self-test result (reviewer run) and the live result reported by the orchestrator for the run before 4a5fd97.

| Test-plan case | Test function | Passing |
|----------------|---------------|---------|
| TC01, TC02, TC03 | `check_ac1` / `ac1_budgets_eval`, `ac1_notifications_eval`, `ac1_subscribers_eval` | Live PASS (AC1) |
| TC04 | selftest on `ac1_*_eval` | Selftest PASS |
| TC05, TC06, TC07, TC08 | `check_ac2` / `ac2_plan_eval`, `ac2_invalid_eval`, `tf_plan_default_rc` | Live PASS (AC2) |
| TC09, TC10, TC11 | `check_ac3` / `ac3_eval` | MANUAL (owner alert test) |
| TC12, TC13, TC14, TC15 | `check_ac4` / `ac4_monitors_eval`, `service_monitor_arn`, `ac4_subscriptions_eval` | Live PASS (AC4) |
| TC16 | selftest on `ac4_*_eval` | Selftest PASS |
| TC17 | `check_ac5` / `ac5_eval` | Live PASS (AC5) |
| TC18 | selftest on `ac5_eval` | Selftest PASS |
| TC19-TC24, TC30 | `check_ac6` / `pick_org_trail`, `ac6_trail_eval`, `ac6_selectors_eval`, `ac6_status_eval`, `ac6_reads_eval`, `events_phase` | Live PASS (AC6) |
| TC25 | selftest on `ac6_*_eval` | Selftest PASS |
| TC26-TC29 | `check_ac7` / `ac7_eval`, `poll_events`, `head_bucket_state`, `cleanup` trap | Live PASS (AC7) |
| TC31, TC32 | `check_ac8` / `ac8_validate_eval`, `ac8_count` | MANUAL until 22:46Z (2 h after StartLoggingTime) |
| TC33 | selftest on `ac8_validate_eval` | Selftest PASS |
| TC34-TC38, TC40 | `check_ac9` / `ac9_versioning_eval`, `ac9_pab_eval`, `ac9_public_eval`, `ac9_encryption_eval`, `ac9_lifecycle_eval`, `ac9_location_eval` | Live PASS (AC9) |
| TC39 | selftest on `ac9_*_eval` | Selftest PASS |
| TC41-TC46 | `check_ac10` / `ac10_trail_eval`, `ac10_budgets_eval`, `sim_run`, `expect_sim` | Live PASS (AC10) |
| TC47-TC52, TC54-TC57, TC59-TC61 | `check_ac11` / `ac11_trail_kind`, `ac11_readme_eval`, `ac11_procedure_eval`, `ac11_notification_eval`, `ac11_policy_readers_eval`, `ac11_acl_eval`, `ac11_tables_eval`, `check_legacy_copy`, `ac11_copy_eval`, `ac11_no_record_eval`, `tc61_eval` | Live PASS except TC53 (before 4a5fd97) |
| TC53 | `count_sensitive`, `tc53_diff_count` (4a5fd97) | Selftest PASS; live re-run pending |
| TC58 | selftest on `ac11_copy_eval` | Selftest PASS |
| TC62 | `check_ac12` / `tags_eval` | Live PASS (AC12) |
| TC63 | selftest on `tags_eval` | Selftest PASS |
| TC64, TC65 | `check_ac13` (MANUAL text names both) | MANUAL (cost in PR) |
| TC66, TC67 | `check_ac14` | Live PASS (AC14); reviewer plan, make test, make lint confirm |
| TC68 | `check_reg68` | Live PASS |
| TC69 | `check_reg69` | Live PASS |
| TC70 | `check_reg70` | Live PASS |
| TC71 | `check_reg71` | Live PASS |
| TC72 | `check_reg72`, `tf_desc_eval` | Live PASS |
| TC73 | logged MANUAL in `main` (run `tests/FND-3.sh`) | MANUAL (PR evidence) |
| TC74 | selftest (missing profile, empty baseline, line order, exit code) | Selftest PASS |

Acceptance criteria:

| AC | Covered by | Status |
|----|------------|--------|
| AC1 | TC01-TC04 | PASS |
| AC2 | TC05-TC08 | PASS |
| AC3 | TC09-TC11 | MANUAL: owner's $0.01 alert test, screenshot and apply times in PR |
| AC4 | TC12-TC16 | PASS |
| AC5 | TC17-TC18 | PASS |
| AC6 | TC19-TC25, TC30 | PASS |
| AC7 | TC26-TC29 | PASS |
| AC8 | TC31-TC33 | MANUAL until 22:46Z; must be PASS in the PR evidence |
| AC9 | TC34-TC40 | PASS |
| AC10 | TC41-TC46 | PASS |
| AC11 | TC47-TC61 | FAIL on TC53 only before 4a5fd97; expected PASS on re-run |
| AC12 | TC62-TC63 | PASS |
| AC13 | TC23, TC24, TC64, TC65 | MANUAL: PR states about $0.50/month (README breakdown: $0.43 PUTs + $0.02 storage) |
| AC14 | TC61, TC66, TC67 | PASS (reviewer confirmed plan no changes, validate, fmt) |

## Test integrity

- The implementer commits (3ca3ab9, f14ceb9) touch only `Makefile`, `guardrails/` and `README.md`. No file under `tests/` was changed, deleted or skipped by the implementer.
- `git diff 95b43d4 HEAD -- tests/` shows only 4a5fd97, a tester commit (`Agent: claude-code/tester`) made on the owner's ruling (run-log 21:39:23Z). It replaces `count_sensitive`'s per-line placeholder exception with per-address stripping (stricter: a real ID or address next to a placeholder is now caught; `x@example.com.au` is not treated as a placeholder) and moves the diff scan into `tc53_diff_count`, which now excludes `tests/` and `docs/`. Self-test cases were added for it, and test-plan TC53 was updated in the same commit. This is a sanctioned test change, not tampering.
- Because TC53 no longer scans `tests/` and `docs/`, the reviewer scanned the whole `main...HEAD` diff (all paths, lock files excluded) for 12-digit numbers, non-placeholder email addresses, and ARNs with account IDs. The only hit is a numeric constant `100000000000` in `tests/FND-4.sh` (epoch-milliseconds heuristic), not an account ID. No email address other than `@example.*` placeholders.

## Rules (branch, trailers, scope, dependencies)

| Rule | Result |
|------|--------|
| Branch `<KEY>-short-description` | `FND-4-cost-audit-guardrails`: OK |
| Trailers on every commit | All 5 commits: `Story: FND-4` and `Agent:` (orchestrator, tester, tester, implementer, implementer) parse as trailers via `%(trailers:...)`; `Co-Authored-By` in the same block: OK |
| Scope | `guardrails/`, `Makefile` (ROOTS, named in design 2), `README.md`, `tests/FND-4*`, `tests/fixtures/FND-4/`, `docs/stories/FND-4/`. No change to `bootstrap/`, `organization/`, `.github/`, `.claude/`, `AGENTS.md` or lint config: OK |
| Dependencies | Same provider as the other roots (`hashicorp/aws ~> 6.0`); no new provider or tool: OK |
| Definition of done: `make test`, `make lint` | Pass (reviewer run) |
| DoD: `terraform plan` no changes after apply | Confirmed by reviewer |
| DoD: `tests/FND-4.sh` passes, output in PR | Pending orchestrator re-run (AC11/TC53) and AC8 after 22:46Z |
| Coding standards | `terraform fmt` clean; region `us-east-1`; variables and outputs documented; no hard-coded account IDs; provider pinned to a range; four cost tags via `default_tags` with the AGENTS.md values; test scripts use `set -euo pipefail` and print one PASS/FAIL/MANUAL line per AC |
| No secrets, IDs or emails committed | None found (see Test integrity); README Offers Platform inventory and commands use placeholders (`<offers-platform-account-id>`, `<old-trail-bucket>`, `<old-trail-arn>`) |
| `.tfvars` untracked | `git ls-files` lists only `guardrails/example.tfvars` and `organization/example.tfvars`; `.gitignore` has `*.tfvars` / `!example.tfvars`, `*.tfstate*`, `.terraform/` |
| Live tfvars state | `budget_limit_override_usd` is not set in `guardrails/terraform.tfvars` (key names only inspected) |
| Boundaries: no account deleted/closed, no root credentials, no NAT, nothing created in member accounts beyond AC7's test bucket | OK. State holds only management-account resources; Offers Platform trail removal was not needed (none found) |
| Access, least privilege, no IAM users, audit | No Identity Center, permission-set or SCP change (REG-TC70 PASS); no IAM users or keys (REG-TC71 PASS); trail created as specified |

## Must fix

None.

Conditions for the PR (evidence, not code changes):
- Attach the re-run of `tests/FND-4.sh` showing AC11 PASS and no FAIL line, with AC8 re-run after 22:46Z showing PASS.
- AC3 owner evidence (email screenshot with address hidden, apply times) and a final `plan` showing no changes with the override back to null.
- AC13 figure (about $0.50/month) and TC73 (`tests/FND-3.sh` re-run) in the PR.
- List the two design deviations (`anomaly_subscription_name`, `guardrails/main.tf`) and the other anomaly monitors/subscriptions left alone (design open question 1) in the PR.

## Suggestions

- README AC3 procedure uses `date -u -v+1d`, which is BSD/macOS-only; a GNU fallback (`date -u -d tomorrow +%F`) would make it portable.
- README duplicate-trail procedure sets `OP_TRAIL_NAME` but never uses it; drop it or use it in the final README table update.
- `guardrails/.terraform.lock.hcl` pins aws 6.73.0 while `bootstrap/` and `organization/` are on 6.71.0. Harmless within `~> 6.0`, but aligning the roots in a later story would keep `make test` runs consistent.
- The `posture` validation allows only `lean`/`working`, but `budget_limits_usd` is a free map; a validation that its keys include both postures would turn a mis-edited map into a plan-time error instead of an index error.
