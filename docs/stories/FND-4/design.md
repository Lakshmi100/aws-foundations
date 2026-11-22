# Design: FND-4 Cost and audit guardrails for the organization

## Revision 2 (2026-11-22, design feedback round 1)

- Requirement 6 trail check: the real `stop-logging` call (`X-REQ6`) is removed. It is replaced by the test plan's no-op `update-trail` from ABC Bank (TC44) and the IAM simulator checks (TC45), both counted in AC10. No test calls `stop-logging` or `delete-trail` (3.8, section 5, D3).
- Posture values stay lowercase, `lean` and `working` (3.2). The test plan's TC05 and TC08 still show the other casing; see open question 8.
- Step I1 now writes the baseline snapshot files the test plan names. The implementer runs it before the guardrails apply, into `${FND4_BASELINE_DIR:-$HOME/.fnd-4-baseline}` outside the repo. It also produces the redacted README inventory (3.9).
- Section 3.8 now uses the test plan's output format: AC1 to AC14, then `REG-TC68` to `REG-TC72`. There are no `X-` lines. Requirement-6 checks count in AC9 and AC10, and the legacy checks count in AC11.
- The legacy copy check now follows TC54 to TC59: key sets match, digest and log counts are equal by type, every object is tagged, and the old bucket's count has not dropped. `FND4_LEGACY_SOURCE` is replaced by a record file in the baseline directory (3.8, 3.9).
- The AC7 test bucket is named `fnd4-audit-test-<random>`. AC3 is an owner step, and the script prints MANUAL for it.
- Interim assumption for anomaly monitors and subscriptions (conflict 2): AC4 fails only on a second `SERVICE` monitor, or on a second subscription on the service monitor. Others are listed in the PR and left alone (3.5, open question 1).

## 1. Analysis

The story adds a new `guardrails/` Terraform root in the management account. It holds:
- one organization-wide monthly cost budget with a posture switch ($100 lean / $300 working) and email alerts at 50, 80 and 100 % of actual spend;
- a per-service Cost Anomaly Detection monitor with a daily $10 email summary;
- the four cost-allocation tags, set to Active;
- an organization CloudTrail trail. The trail is multi-region, records read and write management events, and has log file validation on. It writes to a versioned, private, SSE-S3 bucket with lifecycle rules: 90 days for current objects and 30 days for noncurrent ones.

The story also asks for a one-off manual clean-up of duplicate trails in Offers Platform, documented in `README.md`: take an inventory, copy the logs, check the copy, then delete the trail.

Out of scope: tag policies, per-account budgets, budget actions, data events, CloudWatch Logs or CloudTrail Lake, Config, Security Hub, a KMS key, and any bucket policy that denies the administrator's peers (story decision Q2). The Offers Platform trail deletion and the log copy are documented manual steps, not Terraform resources. They are the story's exception to requirement 8.

The story review left 5 questions open (round 2, Q1 to Q5). The owner's round-1 feedback settles Q3 and Q4. Section 6 lists the rest, together with the questions raised during design and revision.

## 2. Impact

| Component | Files | Change |
|-----------|-------|--------|
| Guardrails root | `guardrails/versions.tf`, `backend.tf`, `providers.tf`, `variables.tf`, `outputs.tf`, `budget.tf`, `anomaly.tf`, `cost_allocation_tags.tf`, `cloudtrail.tf`, `example.tfvars`, `.terraform.lock.hcl` | New. Mirrors the FND-3 reference pattern (FND-3 design 3.1) |
| Commands | `Makefile` | `ROOTS := bootstrap organization guardrails` |
| Acceptance tests | `tests/FND-4.sh` | New. AC1 to AC14, then `REG-TC68` to `REG-TC72` (3.8) |
| Docs | `README.md` | New sections: "Guardrails" (setup, baseline snapshot, AC3 owner procedure, posture switch) and "Offers Platform existing setup (FND-4)" (inventory and the removal procedure). The "What is here" table gains `guardrails/` and `tests/FND-4.sh` |
| `organization/` | none | CloudTrail trusted access is already in `aws_service_access_principals`. No change |
| Member accounts | ABC Bank, Offers Platform | No new resources. CloudTrail adds read-only shadow copies of the organization trail. In Offers Platform, a duplicate trail that records management events only is deleted by hand (3.9) |
| Outside the repo | `${FND4_BASELINE_DIR:-$HOME/.fnd-4-baseline}/` | Read-only JSON snapshot (I1) and the legacy-copy record (I4). Never committed |

## 3. Contract

### 3.1 Root pattern (same as FND-3 3.1)

- `versions.tf`: `required_version = ">= 1.10, < 2.0"`, `hashicorp/aws ~> 6.0`. Commit the lock file.
- `backend.tf`: the same as `organization/backend.tf`, with `key = "guardrails/terraform.tfstate"`. No profile in the file; use `AWS_PROFILE=fnd-management-admin`.
- `providers.tf`: one default provider, `region = "us-east-1"`, `default_tags { tags = var.cost_tags }`. There are no member-account aliases, because this root creates nothing in member accounts.
- Every variable and output has a `description` and a `type`. Personal values go in `guardrails/terraform.tfvars`, which is untracked (`.gitignore` already covers it).
- Account and organization IDs come from `data "aws_caller_identity" "current"` and `data "aws_organizations_organization" "current"`, never from literals.
- `prevent_destroy = true` on the trail and on the trail bucket.

### 3.2 Variables

| Name | Type | Default | Notes |
|------|------|---------|-------|
| `alert_email` | string, `sensitive` | none (required) | Subscriber for the budget and the anomaly subscription. Set in tfvars only |
| `posture` | string | `"lean"` | Validation: exactly `lean` or `working`, case-sensitive. `Working`, `Heavy` and `""` are rejected |
| `budget_limits_usd` | map(number) | `{ lean = 100, working = 300 }` | Limit for each posture |
| `budget_limit_override_usd` | number, nullable | `null` | Only for the AC3 owner step (`0.01`). Validation: null or > 0. Must be back to `null` when the PR merges |
| `budget_name` | string | `"aws-foundations-monthly-cost"` | |
| `anomaly_monitor_name` | string | `"aws-foundations-services"` | If an existing monitor is imported (3.5), set this to its current name so the import shows no rename |
| `anomaly_threshold_usd` | number | `10` | |
| `trail_name` | string | `"aws-foundations-organization-trail"` | |
| `trail_bucket_name` | string | `"aws-foundations-cloudtrail-lakshmi100"` | Must be globally unique. If the name is taken, pick another |
| `log_retention_days` | number | `90` | Expiry for current versions |
| `noncurrent_retention_days` | number | `30` | Expiry for noncurrent versions |
| `cost_tags` | map(string) | same as FND-3 | Also the list of keys for 3.6 |

The effective limit is `local.budget_limit = coalesce(var.budget_limit_override_usd, var.budget_limits_usd[var.posture])`. `example.tfvars` shows `alert_email = "alerts@example.com"`, with the other variables commented out.

### 3.3 Outputs

The root outputs `budget_name`, `budget_limit_usd`, `anomaly_monitor_arn`, `anomaly_subscription_arn`, `trail_arn`, `trail_home_region`, `trail_bucket_name`, `trail_bucket_arn` and `active_cost_allocation_tags` (a list). No output exposes `alert_email`.

### 3.4 Budget (`budget.tf`)

`aws_budgets_budget.organization`:
- `name = var.budget_name`, `budget_type = "COST"`, `time_unit = "MONTHLY"`.
- `limit_amount = format("%.2f", local.budget_limit)`, `limit_unit = "USD"`. The fixed format stops AWS's normalised value from causing a perpetual diff. If the plan still shows a diff after apply, match the format AWS returns.
- No `cost_filter`. In the management account, an unfiltered budget covers the whole consolidated bill.
- `cost_types`: unblended. Use the provider defaults (`use_blended = false`), with credits, refunds and similar settings left at their defaults.
- Three `notification` blocks, for 50, 80 and 100. Each has `comparison_operator = "GREATER_THAN"`, `threshold_type = "PERCENTAGE"`, `notification_type = "ACTUAL"` and `subscriber_email_addresses = [var.alert_email]`.
- Tags come through `default_tags`. If the provider does not apply default tags to budgets, set `tags = var.cost_tags` explicitly.

AC2: switching `posture` changes only `limit_amount`, in place.

AC3 is an owner step that the script reports as MANUAL:
1. The owner sets `budget_limit_override_usd = 0.01`, either in tfvars or with `-var`, and applies.
2. The owner waits for the alert email.
3. The owner sets the variable back to `null` and applies again. After that, `plan` shows no changes.

The README records this procedure. It notes that the test should run when month-to-date spend is above $0.00.

### 3.5 Anomaly detection (`anomaly.tf`)

- `aws_ce_anomaly_monitor.services`: `name = var.anomaly_monitor_name`, `monitor_type = "DIMENSIONAL"`, `monitor_dimension = "SERVICE"`.
- `aws_ce_anomaly_subscription.daily`:
  - `name = "aws-foundations-daily-summary"`, `frequency = "DAILY"`;
  - `monitor_arn_list = [aws_ce_anomaly_monitor.services.arn]`;
  - one `subscriber { type = "EMAIL", address = var.alert_email }`;
  - `threshold_expression { dimension { key = "ANOMALY_TOTAL_IMPACT_ABSOLUTE", match_options = ["GREATER_THAN_OR_EQUAL"], values = [tostring(var.anomaly_threshold_usd)] } }`.
- Both resources are tagged.

**Pre-apply import step (README, story decision Q1).** It uses the I1 baseline files `mgmt-anomaly-monitors.json` and `mgmt-anomaly-subscriptions.json`:
1. If a `DIMENSIONAL`/`SERVICE` monitor exists, run `terraform import aws_ce_anomaly_monitor.services <arn>` and set `anomaly_monitor_name` to its name.
2. If a subscription references that monitor, run `terraform import aws_ce_anomaly_subscription.daily <arn>`. The next apply changes its subscriber, frequency and threshold in place to requirement 3's values. Its `name` changes to the contract name only if the API allows an in-place change; otherwise `name` is set to the existing name.

The interim assumption for AC4 (conflict 2, to be confirmed at the gate) is:
- AC4 fails if there is more than one `SERVICE` monitor, or more than one subscription whose `MonitorArnList` contains the service monitor.
- Monitors of other types, and subscriptions on other monitors only, are left alone. The script prints them to stderr (names only) for the PR list.

### 3.6 Cost-allocation tags (`cost_allocation_tags.tf`)

`aws_ce_cost_allocation_tag.this` uses `for_each = toset(keys(var.cost_tags))`, with `tag_key = each.key` and `status = "Active"`.

The README pre-check before apply is `aws ce list-cost-allocation-tags --tag-keys data-product environment owner cost-center`. All four keys must be listed, with any status. A missing key means AWS has not yet seen it on a billed resource. Wait for it; do not create a resource just to make it appear.

### 3.7 CloudTrail and its bucket (`cloudtrail.tf`)

Bucket `aws_s3_bucket.trail`:
- `bucket = var.trail_bucket_name`, `force_destroy = false`, `prevent_destroy`.
- `aws_s3_bucket_versioning`: `Enabled`.
- `aws_s3_bucket_server_side_encryption_configuration`: `AES256`.
- `aws_s3_bucket_public_access_block`: all four settings `true`.
- `aws_s3_bucket_ownership_controls`: `BucketOwnerEnforced`.
- `aws_s3_bucket_lifecycle_configuration` covers the whole bucket (empty filter), so it applies to both `AWSLogs/` and `legacy/`:
  - rule `expire-logs`: `expiration { days = var.log_retention_days }`, `noncurrent_version_expiration { noncurrent_days = var.noncurrent_retention_days }`, `abort_incomplete_multipart_upload { days_after_initiation = 7 }`;
  - rule `remove-expired-delete-markers`: `expiration { expired_object_delete_marker = true }`. This is a separate rule because S3 does not allow the flag in the same expiration as `days`.

The bucket policy `aws_s3_bucket_policy.trail` is built with `aws_iam_policy_document`. It has `depends_on` the public access block and exactly three statements:

| Effect | Principal | Action | Resource | Condition |
|--------|-----------|--------|----------|-----------|
| Allow | Service `cloudtrail.amazonaws.com` | `s3:GetBucketAcl` | bucket ARN | `StringEquals aws:SourceArn = <trail ARN>` |
| Allow | Service `cloudtrail.amazonaws.com` | `s3:PutObject` | `bucket/AWSLogs/<mgmt-id>/*`, `bucket/AWSLogs/<org-id>/*` | `StringEquals s3:x-amz-acl = bucket-owner-full-control` and `aws:SourceArn = <trail ARN>` |
| Deny | `*` | `s3:*` | bucket, `bucket/*` | `Bool aws:SecureTransport = false` |

`<trail ARN>` is built as `arn:<partition>:cloudtrail:us-east-1:<mgmt-id>:trail/<trail_name>`, which avoids a dependency cycle. There is no admin-only deny (story Q2; see D3). The management Administrator role writes under `legacy/` through IAM.

Trail `aws_cloudtrail.organization`:
- `name = var.trail_name` and `s3_bucket_name = aws_s3_bucket.trail.id`, with no key prefix.
- `is_organization_trail = true`, `is_multi_region_trail = true`, `include_global_service_events = true`, `enable_log_file_validation = true`, `enable_logging = true`.
- `event_selector { read_write_type = "All", include_management_events = true }`, with no data resources and no excluded event sources.
- No CloudWatch Logs, SNS, KMS or Insights.
- `depends_on = [aws_s3_bucket_policy.trail]`, `prevent_destroy`.

Log layout, used by AC7 and AC8: `AWSLogs/<org-id>/<account-id>/CloudTrail/<region>/YYYY/MM/DD/` and `.../CloudTrail-Digest/...`.

### 3.8 `tests/FND-4.sh`

The script follows the conventions of `tests/FND-3.sh`:
- `#!/usr/bin/env bash`, `set -euo pipefail`, `AWS_PAGER=""`;
- profiles come from `FND_MANAGEMENT_ADMIN`, `FND_ABC_BANK_ADMIN` and `FND_OFFERS_PLATFORM_ADMIN`, plus the ABC Bank engineering profile for REG-TC69, with the FND-3 defaults;
- account IDs come only from `sts get-caller-identity` and are never printed;
- the alert email is read from `FND4_ALERT_EMAIL` or from `guardrails/terraform.tfvars`, and is never printed;
- `BASELINE=${FND4_BASELINE_DIR:-$HOME/.fnd-4-baseline}`. A missing baseline file is FAIL for the lines that need it.

The output is exactly 19 lines on stdout, in this order: `AC1` to `AC14`, then `REG-TC68`, `REG-TC69`, `REG-TC70`, `REG-TC71`, `REG-TC72`. Each line has the form `PASS|FAIL|MANUAL <ID> <text>`. There are no other ID lines. A failing check sets its line to FAIL; it does not abort the script. The script exits 1 if any line is FAIL. Supporting detail goes to stderr.

Notes on individual lines (case numbers are from the test plan):
- **AC2** (TC05 to TC08): `terraform plan -detailed-exitcode -var posture=working -out <scratch>`, then `terraform show -json`. The only changed attribute must be the budget's `limit_amount`, updated in place. Plans with no posture set and with `posture=lean` must exit 0. Plans with `Working`, `Heavy` and `""` must fail validation. Nothing is ever applied, and the scratch plan file is deleted.
- **AC3**: always MANUAL. The line includes the month-to-date unblended spend, or "wait until month-to-date spend is above $0.00". The automated parts (TC11: live limit equals the posture limit, never 0.01, and the plan exits 0) can turn the line into FAIL.
- **AC4**: applies the interim rule in 3.5. TC14 compares against `mgmt-anomaly-monitors.json` and `terraform state`.
- **AC7** is the only check that creates anything. It creates `fnd4-audit-test-<random>` in ABC Bank in `us-east-1`, with the four cost tags, deletes it straight away, and has a `trap` delete on exit. It then polls `AWSLogs/<org-id>/<abc-id>/CloudTrail/us-east-1/` for up to 30 minutes for the `CreateBucket` and `DeleteBucket` events. Finally, `head-bucket` must return 404.
- **AC8**: MANUAL "rerun after <time>" if `StartLoggingTime` is less than 2 hours ago. Otherwise it runs `validate-logs` for the previous whole hour, for the management account and with `--account-id` for each member. At least one digest file and one log file must be validated, with none invalid or missing.
- **AC9** includes TC38, the `expired_object_delete_marker` rule (requirement 6).
- **AC10** includes the requirement-6 checks:
  - TC44: from `FND_ABC_BANK_ADMIN`, run the no-op `aws cloudtrail update-trail --name <org trail ARN> --enable-log-file-validation`. The call must fail, and the trail must then be unchanged and still logging.
  - TC45: `iam simulate-principal-policy` for both member administrator roles against the trail bucket policy, and real read-only `list-objects-v2` and `get-bucket-lifecycle-configuration` calls from ABC Bank, which must be denied.
  - TC46: only the Administrator permission set is assigned in the management account.
  - No test calls `stop-logging` or `delete-trail`.
- **AC11** covers TC47 to TC61:
  - `describe-trails` without shadow trails, in every enabled region of Offers Platform;
  - README compared with the baseline files;
  - baseline budgets, monitors and subscriptions still present and unchanged;
  - kept trails unchanged.
  
  The legacy copy is checked against `$BASELINE/legacy-copy.json` (3.9 I4):
  - If the file is absent, no trail was removed. The copy checks are "not applicable" and `legacy/offers-platform-account-trail/` must be empty (TC59).
  - If the file is present, for each source listed:
    - the reader checks on the old bucket find nothing (TC54);
    - `head-bucket` succeeds, and the old prefix's object count is at least the recorded count (TC55);
    - the paginated key sets match: every source key `K` has `legacy/offers-platform-account-trail/K`, with equal counts of log files and of `CloudTrail-Digest` files (TC56);
    - `get-object-tagging` shows `source=offers-platform-account-trail` on every copied object (TC57).
- **AC12** reads tags with each service's own call: `cloudtrail list-tags`, `s3api get-bucket-tagging`, `budgets list-tags-for-resource` and `ce list-tags-for-resource`.
- **AC13**: MANUAL, with bucket size and legacy prefix size printed to stderr.
- **REG-TC68 to REG-TC72**, as in the test plan.

### 3.9 Offers Platform existing setup (README procedure, story requirement 7 and decision Q3)

The implementer runs these steps with `fnd-offers-platform-admin` and `fnd-management-admin` (open question 6).

| Step | When | What |
|------|------|------|
| I1 | Before the guardrails apply, read-only | Write the baseline to `${FND4_BASELINE_DIR:-$HOME/.fnd-4-baseline}` (created with mode 700, outside the repo, never committed). Files: `op-trails.json` (Offers Platform `describe-trails --no-include-shadow-trails` in every enabled region, plus `get-trail`, `get-event-selectors`, `get-insight-selectors` and `get-trail-status` for each trail); `op-budgets.json` (`budgets describe-budgets`); `op-anomaly-monitors.json`; `op-anomaly-subscriptions.json`; `mgmt-anomaly-monitors.json` and `mgmt-anomaly-subscriptions.json` (management account). Each file is the raw JSON of the calls, keyed by call and region. From these files, write the redacted inventory into README (open question 5) |
| I2 | After the organization trail is logging (AC6 passes), so no events are lost in between | Consider each trail that records management events only (no data, Insights or network-activity selectors), with no `CloudWatchLogsLogGroupArn` and no `SnsTopicARN`. Run the TC54 reader checks on its bucket: `get-bucket-notification-configuration` (S3 and EventBridge), `get-bucket-replication`, `s3control list-access-points --bucket`, `get-bucket-policy`, `get-bucket-acl`, and `glue get-tables` (and `athena list-table-metadata` where used) for a location under the bucket. Any hit: keep the trail and record it in README |
| I3 | After I2 passes | Copy `<prefix>/AWSLogs/<op-id>/CloudTrail/` and `CloudTrail-Digest/`. First `aws s3 sync` them down with the Offers Platform admin profile to a temporary directory outside the repo. Then upload each object with the management admin profile to `legacy/offers-platform-account-trail/<original key>`, with the tag `source=offers-platform-account-trail` (`s3api put-object --tagging`). Delete the temporary directory afterwards |
| I4 | After I3 | Run the same checks as AC11's TC56 and TC57 (key sets, counts by type, tags). If any check differs, stop and do not delete the trail. If all pass, write `$BASELINE/legacy-copy.json`: a list of `{ "trail_name", "source_bucket", "source_prefix", "object_count", "log_count", "digest_count", "copied_at" }`, one entry for each removed trail |
| I5 | After I4 | `aws cloudtrail delete-trail --name <trail ARN>` with the Offers Platform admin profile. The old bucket stays as it is |

## 4. Data model

New persistent state, all in the management account:
- one budget;
- one anomaly monitor and one subscription, either new or imported;
- four cost-allocation tag statuses;
- one organization trail;
- one S3 bucket. It holds about 120 days of logs (90 days current plus 30 days noncurrent), plus any copied `legacy/` logs, which expire 90 days after the copy;
- the state file `guardrails/terraform.tfstate`, which holds the alert email.

Outside the repo, on the implementer's machine: the baseline directory (I1) and `legacy-copy.json` (I4). They hold account IDs and ARNs, so they are never committed.

Effect on existing data:
- Member accounts' management events are now also delivered to the management bucket.
- In Offers Platform, a qualifying duplicate trail stops writing. Its existing logs stay in their old bucket, and a copy is kept under `legacy/` for 90 days.
- Copied digest files cannot be validated in place, because digests refer to their original keys. The originals in the old bucket stay valid.
- An imported anomaly subscription changes its subscriber and threshold (open question 1).

## 5. Risks

| Risk | Mitigation / how tests catch it |
|------|------|
| A tag key has not yet been seen on a billed resource, so `aws_ce_cost_allocation_tag` fails | The 3.6 pre-check. The apply fails cleanly and nothing is left half-done. AC5 |
| The bucket policy is wrong, so the trail create fails (`InsufficientS3BucketPolicyException`) | The trail `depends_on` the policy. AC6 and AC7 |
| `limit_amount` formatting causes a perpetual diff | The fixed format in 3.4. AC14 and AC2 |
| AC3's override is left at 0.01, which causes false alerts | AC3 (TC11) fails on a live limit of 0.01, AC1 checks $100, and AC14 checks for drift. The README procedure ends with the revert |
| AC7's test bucket is left behind in ABC Bank | `trap` delete, and the `head-bucket` 404 check |
| The TC44 no-op `update-trail` unexpectedly succeeds | It sets a value the trail already has, so nothing changes. The line is FAIL, and the owner reviews member permissions |
| The duplicate trail is deleted before the organization trail logs, which leaves a gap in audit | I2 to I5 run only after AC6 passes (D2) |
| The baseline is taken after the apply, or not at all | README orders I1 before apply. A missing baseline is FAIL for AC4 and AC11 |
| The old trail bucket uses SSE-KMS and the admin cannot decrypt it | The I3 download fails. Stop and ask. Do not change key policies |
| Cost goes over $2 | See the estimate below and open question 2 |

Monthly cost estimate:
- Management events on one trail: $0.
- Budgets without actions: $0.
- Anomaly detection and cost-allocation tags: $0.
- S3 PUTs for digest files: about 3 accounts × 17 regions × 24 digests a day, which is about 37k a month, roughly $0.18.
- S3 PUTs for log files: about 50k a month for a lightly used organization, roughly $0.25.
- Storage: under 1 GB over 120 days, roughly $0.02.
- Expected total: about $0.50 a month.

Delivery in idle regions is the uncertain part. The implementer checks the bucket's tagged S3 cost in Cost Explorer after a few days and puts that figure in the PR (AC13). If it trends over $2, stop and ask.

## 6. Open questions

| # | Question | Recommended assumption |
|---|----------|------------------------|
| 1 | Story review Q1 and conflict 2 (not yet decided by the owner): other anomaly monitors and subscriptions in the management account | Interim assumption: import a `SERVICE` monitor and its subscription, and change the subscription in place to `alert_email`, daily, $10 (3.5). AC4 fails only on a second `SERVICE` monitor, or on a second subscription on the service monitor. Other monitors and subscriptions are listed in the PR and left alone. TC12 and TC15 in the test plan need to match this; the owner confirms at the gate |
| 2 | Story review Q2 (open): if the total goes over $2 (because of a kept trail or the copied logs), which wins? Is the one-time copy cost part of AC13? | Stop and bring it to the owner before keeping or copying anything that pushes the monthly total over $2. AC13 reports the recurring monthly figure, including storage of copied logs while they exist. The one-time copy cost is reported separately in the PR |
| 3 | Story review Q3: how is the legacy copy checked? | Settled by the owner (round 1, item 6): TC54 to TC59, counted in AC11 (3.8) |
| 4 | Story review Q4: how is requirement 6 checked? | Settled by the owner (round 1, item 1): TC44 no-op `update-trail`, TC45 and TC46 in AC10, and the delete-marker rule in AC9 |
| 5 | Story review Q5 (open): what may the public README record about Offers Platform trails, budgets and monitors, and in the commands? | FND-3's redaction rule applies. README records names, settings and the action taken. Account IDs, ARNs and bucket names are placeholders (`<offers-platform-account-id>`, `<old-trail-bucket>`). Emails appear as labels. Commands use shell variables. The owner reviews before commit |
| 6 | Who runs the manual steps (I1 to I5)? | The implementer, with the two administrator profiles. Each outcome is recorded, redacted, in the PR. If any check is unclear, stop and ask before I5 |
| 7 | What if the existing monitor is not a `SERVICE` monitor? | Import only a `SERVICE` monitor, because a monitor's type cannot be changed in place. Leave any other kind alone and list it in the PR. This is consistent with row 1 |
| 8 | Posture casing: the owner chose lowercase `lean` and `working`, but test plan TC05 and TC07 still use `Working` and `Lean`, and TC08 still lists lowercase `working` as rejected | The design builds on the owner's decision (feedback item 3). The tester updates TC05, TC07 and TC08: plan with `working` and `lean`, and reject `Working`, `Heavy` and `""` |
| 9 | TC55 needs "the count at the copy", and no baseline file named in the test plan holds it | Add `legacy-copy.json` to the baseline directory (3.9 I4). It replaces the old `FND4_LEGACY_SOURCE` variable. The tester confirms |

## 7. Sequence diagram

```mermaid
sequenceDiagram
    actor Impl as Implementer (admin profiles)
    participant BL as Baseline dir (outside repo)
    participant OP as Offers Platform
    participant TF as guardrails/ Terraform (mgmt)
    participant CE as Budgets / Cost Explorer
    participant CT as CloudTrail + trail bucket
    Impl->>OP: I1 read trails, budgets, monitors, subscriptions
    Impl->>CE: I1 read mgmt monitors, subscriptions; tag-key pre-check
    Impl->>BL: write op-*.json, mgmt-*.json; README inventory (redacted)
    Impl->>TF: import existing SERVICE monitor/subscription (if any)
    TF->>CE: budget, monitor, subscription, 4 active tags
    TF->>CT: bucket (+policy, lifecycle), organization trail
    CT-->>OP: shadow trail; events delivered to mgmt bucket
    Impl->>CT: AC6 get-trail-status logging
    Impl->>OP: I2 reader checks on duplicate trail's bucket
    Impl->>CT: I3 download (OP admin) / upload to legacy/ (mgmt admin), tagged
    Impl->>BL: I4 key-set, count, tag checks pass; write legacy-copy.json
    Impl->>OP: I5 delete-trail (old bucket kept)
    Impl->>Impl: tests/FND-4.sh; owner runs AC3 override + revert
```

## 8. Decision record

- **D1 Posture switch.**
  - Options: a single `budget_limit` number; a `posture` enum with a map of limits; a separate override.
  - Decision: a `posture` enum (`lean`, `working`, lowercase) with a map, plus a nullable `budget_limit_override_usd` used only for AC3.
  - Why: requirement 2 asks for "one variable switched", and AC3 needs the change made "through Terraform" without redefining the posture.
  - Consequence: AC2's plan shows only `limit_amount`.
- **D2 When the duplicate trail is removed.**
  - Options: before the organization trail is created, or after it logs.
  - Decision: the inventory and baseline are taken before the apply (requirement 7); the removal happens after AC6 passes.
  - Why: there is no gap in Offers Platform audit.
  - Consequence: for a short window, events are recorded twice (a few cents at most).
- **D3 The trail bucket policy differs from the bootstrap pattern.**
  - Context: `bootstrap/` denies `s3:*` to every principal whose `aws:PrincipalArn` is not the Administrator role or root.
  - Options: copy that deny, or leave it out.
  - Decision: leave it out (story decision Q2).
  - Why: service principals carry no `aws:PrincipalArn`, so the `ArnNotLike` deny would also block CloudTrail's writes. An exception for CloudTrail is the "future enhancement" that Q2 puts out of scope.
  - Consequence: protection rests on IAM, because member accounts cannot reach the management bucket or change the organization trail. AC10 checks this with TC44 and TC45 without any real stop or delete.
- **D4 Two lifecycle rules.**
  - S3 rejects `expired_object_delete_marker` in the same expiration as `days`.
  - So one rule holds the expiry and noncurrent expiry, and another holds the delete-marker cleanup. Both cover the whole bucket, so `legacy/` follows the same retention.
