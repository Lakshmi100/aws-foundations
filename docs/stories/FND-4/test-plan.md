# Test plan: FND-4 Cost and audit guardrails for the organization

Written from the story only, independently of the design.

**Revision 2 (2026-11-22, design feedback round 1).** Changes:
- Posture values are lowercase `lean` and `working`: TC05 and TC06 plan with
  `working`, TC07 with `lean`, TC11 compares against the configured posture,
  TC08 rejects `Heavy`, an empty string and capitalised `Working`. Q10 resolved.
- Baseline snapshot is taken by the implementer, read-only, before the
  `guardrails/` apply, in `${FND4_BASELINE_DIR:-$HOME/.fnd-4-baseline}`. Q6
  resolved.
- Anomaly monitors and subscriptions (interim assumption, owner to confirm at
  the gate): TC12, TC14 and TC15 FAIL only on a second SERVICE monitor or a
  second subscription on the service monitor; other monitors and
  subscriptions are listed in the PR and left alone. Q1 updated.
- AC7 test bucket name stays `fnd4-audit-test-<random>`. Q13 resolved.
- TC44 stays a no-op `update-trail` from ABC Bank; no test calls
  `stop-logging` or `delete-trail`. Q4 updated.
- AC3 is an owner step the script reports as MANUAL. Q8 resolved.
- Output lines confirmed: one per criterion AC1 to AC14, then `REG-TC68` to
  `REG-TC72` (TC74 unchanged).

All cases are checks in `tests/FND-4.sh` against the real accounts. The script
prints one PASS, FAIL or MANUAL line per acceptance criterion; a criterion is
PASS only when every automated case tagged with it passes, and MANUAL when its
automated cases pass but a person still has to check something. Notes that
apply to many cases:

- Profiles are the FND-3 Identity Center profiles: management administrator,
  ABC Bank administrator, Offers Platform administrator (and the ABC Bank
  engineering profile for one regression). Account IDs come from each profile's
  `aws sts get-caller-identity`, never from values written into the script.
- "The engineer's email" is read from the environment (`FND4_ALERT_EMAIL`) or
  from the untracked `.tfvars`. The script compares it but never prints it;
  output shows it masked (for example `l***@***`).
- "The cost tags" means exactly `data-product=aws-foundations`,
  `environment=shared`, `owner=Lakshmi100`,
  `cost-center=offers-platform-portfolio` (keys and values case-sensitive).
- **Baseline (requirement 7, the Nov 22 Q1 decision, design feedback round 1
  item 4).** The implementer takes a read-only JSON snapshot before the
  `guardrails/` apply (before the organization trail is created), outside
  the repo in `${FND4_BASELINE_DIR:-$HOME/.fnd-4-baseline}`, never committed:
  `op-trails.json` (Offers Platform `describe-trails` per region, with
  `get-event-selectors`, `get-insight-selectors` and `get-trail-status` per
  trail), `op-budgets.json`, `op-anomaly-monitors.json`,
  `op-anomaly-subscriptions.json`, and `mgmt-anomaly-monitors.json`,
  `mgmt-anomaly-subscriptions.json` for the management account. A missing or
  unreadable baseline is FAIL for the cases that need it, never skipped.
- The script changes AWS only where a criterion says so: AC7 creates and
  deletes one test S3 bucket in ABC Bank (removed by a `trap` on any exit).
  AC2's `working` posture is only planned, never applied. AC3's $0.01 limit is
  a manual owner step. Checks that a member account cannot change the trail or
  its bucket use either a no-op call (same values as today) or the IAM policy
  simulator, never a real stop or delete.
- "Stubbed response" cases test the script's check functions with canned JSON,
  not by changing AWS.

## Cases
| ID | Covers (AC #) | Type | Scenario | Expected result |
|----|---------------|------|----------|-----------------|
| TC01 | AC1 | positive | Management admin: `aws budgets describe-budgets --account-id <mgmt>`. | Exactly one budget with `BudgetType: COST`, `TimeUnit: MONTHLY`, `BudgetLimit` 100 USD (compared as a number, so `100.0` passes). No cost filters (whole organization). Cost types use unblended cost (not blended, not amortized; credits and refunds treatment as AWS defaults). |
| TC02 | AC1 | positive | `aws budgets describe-notifications-for-budget` for that budget. | Exactly three notifications, each `NotificationType: ACTUAL`, `ComparisonOperator: GREATER_THAN` (AWS's operator for "spend reaches the threshold"), `ThresholdType: PERCENTAGE`, thresholds 50, 80 and 100. |
| TC03 | AC1 | positive | `aws budgets describe-subscribers-for-notification` for each of the three. | Each has exactly one subscriber, `SubscriptionType: EMAIL`, address equal to the engineer's email. |
| TC04 | AC1 | boundary | Stubbed responses: limit 100.01 or 99.99; thresholds 50/80 only; 50/80/100/100 (duplicate); a 100% `FORECASTED` notification instead of `ACTUAL`; `ThresholdType: ABSOLUTE_VALUE` 100; two cost budgets; zero budgets; subscriber with a different address or `SNS`. | AC1 prints FAIL in every case. |
| TC05 | AC2 | positive | In `guardrails/`: `terraform plan -detailed-exitcode -var <posture variable>=working -out <scratch>`; `terraform show -json` on the plan. | Exit 2. `resource_changes` has exactly one entry with actions other than `no-op`: the budget, action `update` (not replace). The only changed attribute is the limit amount, 100 to 300. Scratch plan file deleted. |
| TC06 | AC2 | negative | Same `working` plan: inspect the budget's notifications and subscribers in the plan. | Thresholds stay 50/80/100 percent of actual and subscribers unchanged; no create or destroy of any resource. |
| TC07 | AC2 | positive | `terraform plan -detailed-exitcode` with no posture override, and again with the posture variable set explicitly to `lean`. Then `describe-budgets`. | Both exit 0 (`lean` is the default and equals the applied state); live limit is 100 USD. This is the "switching back returns it to $100" check: `working` is never applied by the script. |
| TC08 | AC2 | boundary | `terraform plan` with the posture variable set to each unsupported value in turn: `Heavy`, an empty string, `Working` (capitalised). | Each plan fails with a variable validation error; none silently falls back to $100 or produces another limit. Only `lean` and `working` are accepted (Q10, resolved). |
| TC09 | AC3 | positive (MANUAL) | Owner procedure: confirm month-to-date spend above $0.00 (`aws ce get-cost-and-usage`, current month, `UnblendedCost`); set the limit to $0.01 through Terraform and apply; wait for the email; set it back through Terraform and apply. | Budget alert email arrives within 24 hours of the apply. Script prints MANUAL with the month-to-date figure; screenshot of the email (address masked) and the apply times in the PR. |
| TC10 | AC3 | boundary | Script reads month-to-date unblended cost. | If it is $0.00, AC3 prints MANUAL "wait until month-to-date spend is above $0.00", never PASS. |
| TC11 | AC3 | positive | After the owner resets the limit: `describe-budgets` and `terraform plan -detailed-exitcode` in `guardrails/`. | Limit is 100 USD (`lean`, or 300 if the owner has chosen `working`, matching the configured posture); plan exit 0. A live limit of 0.01 is FAIL. |
| TC12 | AC4 | positive | Management admin: `aws ce get-anomaly-monitors`. | Exactly one monitor with `MonitorType: DIMENSIONAL`, `MonitorDimension: SERVICE`. Other monitors (for example `CUSTOM` or linked-account monitors) do not affect the result; the script lists them (name and type) for the PR. A second SERVICE monitor is FAIL. See Q1. |
| TC13 | AC4 | positive | `aws ce get-anomaly-subscriptions`. | A subscription whose `MonitorArnList` contains TC12's monitor, `Frequency: DAILY`, one `EMAIL` subscriber equal to the engineer's email (the same address as TC03), threshold $10 on absolute total impact, inclusive (`ThresholdExpression` on `ANOMALY_TOTAL_IMPACT_ABSOLUTE` with `GREATER_THAN_OR_EQUAL` 10, or legacy `Threshold: 10`). |
| TC14 | AC4 (Nov 22 Q1 decision) | negative | Compare live monitors with `mgmt-anomaly-monitors.json` (baseline) and `terraform state` in `guardrails/`. | If the baseline had a service monitor, its ARN is the one Terraform manages (imported, not replaced) and no second service monitor exists. If the baseline had none, exactly one exists and it is in state. Two service monitors is FAIL. Every non-service monitor in the baseline still exists, unchanged (left alone), and is listed for the PR. |
| TC15 | AC4 (review Q1) | negative | List all anomaly subscriptions in the management account; compare with `mgmt-anomaly-subscriptions.json` (baseline). | Exactly one subscription whose `MonitorArnList` contains TC12's service monitor: TC13's. A second subscription on the service monitor is FAIL. Subscriptions not on the service monitor are listed for the PR and left alone: each one in the baseline still exists, unchanged. Interim assumption, see Q1. |
| TC16 | AC4 | boundary | Stubbed responses: `Frequency: WEEKLY` or `IMMEDIATE`; threshold 9.99, 100 or 10 percent (`ANOMALY_TOTAL_IMPACT_PERCENTAGE`); `GREATER_THAN` 10 instead of `>=`; `MonitorDimension` missing or a `CUSTOM` monitor; subscriber `SNS`. | AC4 prints FAIL in every case. |
| TC17 | AC5 | positive | Management admin: `aws ce list-cost-allocation-tags --tag-keys data-product environment owner cost-center`. | All four returned, `Type: UserDefined`, `Status: Active`. |
| TC18 | AC5 | boundary | Stubbed responses: one key `Inactive`; a key missing from the list (AWS has not seen it on a billed resource yet); `Owner` active but `owner` not. | AC5 prints FAIL, naming the key. A missing key's message says the tag has not been seen on a billed resource yet. |
| TC19 | AC6 | positive | Management admin, `us-east-1`: `aws cloudtrail describe-trails`. | Exactly one trail with `IsOrganizationTrail: true`, `IsMultiRegionTrail: true`, `LogFileValidationEnabled: true`, `IncludeGlobalServiceEvents: true`, `HomeRegion: us-east-1`, ARN in the management account, `S3BucketName` a bucket owned by the management account. |
| TC20 | AC6 | positive | `aws cloudtrail get-event-selectors` on it. | Management events included with read and write (`ReadWriteType: All`, or advanced selectors with `eventCategory = Management` and no `readOnly` filter). No `ExcludeManagementEventSources`. No data event selectors (out of scope). See Q11. |
| TC21 | AC6 | positive | `aws cloudtrail get-trail-status`. | `IsLogging: true`; `LatestDeliveryError` and `LatestDigestDeliveryError` empty; `LatestDeliveryTime` within the last 2 hours. |
| TC22 | AC6 | positive | `describe-trails --include-shadow-trails` and `get-trail-status` in another region (`us-west-2`, and `eu-west-1`). | The organization trail appears with `HomeRegion: us-east-1` and is logging: all regions are covered. |
| TC23 | AC6, AC13 | negative | Same trail record. | No `CloudWatchLogsLogGroupArn`, no `SnsTopicARN`, no `KmsKeyId` (CloudWatch Logs delivery and customer-managed keys are out of scope and cost money). No Insights selectors. |
| TC24 | AC6, AC13 | boundary | `describe-trails --include-shadow-trails` in the management account. | Exactly one organization trail. A second organization trail (a second billed copy of management events) is FAIL. |
| TC25 | AC6 | boundary | Stubbed responses: `IsMultiRegionTrail: false`; validation off; `ReadWriteType: WriteOnly` or `ReadOnly`; `IsLogging: false`; `IsOrganizationTrail: false`. | AC6 prints FAIL in each. |
| TC26 | AC7 | positive | ABC Bank admin: `aws s3api create-bucket` for `fnd4-audit-test-<random>` in `us-east-1` (tagged with the cost tags), then `delete-bucket`. Management admin polls the trail bucket under the ABC Bank account's CloudTrail prefix for today's date, every minute, for up to 30 minutes, reading log files and searching for the bucket name. | A `CreateBucket` and a `DeleteBucket` event for that bucket, with `recipientAccountId` = ABC Bank, found within 30 minutes of the delete. |
| TC27 | AC7 | positive | Same events. | `userIdentity.arn` is the ABC Bank administrator Identity Center role (`AWSReservedSSO_...`) session: the trail shows who did it. |
| TC28 | AC7 | negative | Cleanup: after the run (and on any exit, including errors and interrupt), ABC Bank admin `aws s3api head-bucket` on the test bucket. | 404 / Not Found. A test bucket left behind is FAIL. |
| TC29 | AC7 | boundary | Events first seen after 30 minutes, or only one of the two events seen. | AC7 prints FAIL with the elapsed time. Exactly 30:00 counts as within. |
| TC30 | AC6 (req 5) | positive | The script's own read calls (`aws s3api list-buckets`) from the management, ABC Bank and Offers Platform admin profiles; poll the trail bucket under each account's prefix for up to 30 minutes. | A `ListBuckets` event (a read management event) for each of the three accounts. Proves all three accounts and read events are recorded. |
| TC31 | AC8 | positive | `get-trail-status` `StartLoggingTime` at least 2 hours ago; `aws cloudtrail validate-logs --trail-arn <org trail> --start-time <start of previous hour> --end-time <end of previous hour>`. | Exit 0; output reports all digest files and all log files valid, with 0 invalid and 0 missing; at least one digest file and one log file validated. |
| TC32 | AC8 | boundary | `StartLoggingTime` less than 2 hours ago. | AC8 prints MANUAL "rerun after <time>", not PASS. See Q9. |
| TC33 | AC8 | boundary | Stubbed outputs: "0/0 digest files valid"; "1 digest file INVALID"; a log file reported missing. | AC8 prints FAIL. Zero files validated is never PASS. |
| TC34 | AC9 | positive | Management admin, trail bucket: `get-bucket-versioning`. | `Status: Enabled`. |
| TC35 | AC9 | positive | `get-public-access-block`; `get-bucket-policy-status`; `get-bucket-acl`; `get-bucket-policy`. | All four public access block settings `true`; `IsPublic: false`; no ACL grant to AllUsers or AuthenticatedUsers; no policy statement allows `Principal: "*"` without a condition limiting it to CloudTrail. |
| TC36 | AC9 | positive | `get-bucket-encryption`. | Default encryption `AES256` (S3-managed). `aws:kms` or `aws:kms:dsse` is FAIL (customer-managed KMS is out of scope and has a cost). |
| TC37 | AC9 | positive | `get-bucket-lifecycle-configuration`. | Enabled rule(s) applying to the whole bucket (empty filter or prefix, so `legacy/` is included): `Expiration.Days: 90` for current objects and `NoncurrentVersionExpiration.NoncurrentDays: 30`. |
| TC38 | AC9 (req 6, review Q4) | positive | Same lifecycle configuration. | An enabled rule with `Expiration.ExpiredObjectDeleteMarker: true` (or equivalent) removes expired delete markers. Assumption, see Q4. |
| TC39 | AC9 | boundary | Stubbed configurations: expiration 89 or 91 days; noncurrent 29 or 31 days; rule `Disabled`; rule filtered to `AWSLogs/` only (so `legacy/` never expires); no noncurrent rule; versioning `Suspended`; one public access block setting `false`. | AC9 prints FAIL in each. |
| TC40 | AC9 | positive | `get-bucket-location` and `aws s3api list-buckets` with the management admin. | Bucket is in `us-east-1` and owned by the management account. |
| TC41 | AC10 | positive | ABC Bank admin, `us-east-1`: `aws cloudtrail describe-trails --include-shadow-trails`. | The organization trail is listed with `IsOrganizationTrail: true`, `HomeRegion: us-east-1`, and a `TrailARN` whose account is the management account. |
| TC42 | AC10 | negative | ABC Bank admin: `aws budgets describe-budgets --account-id <ABC Bank>`. | No budget with the organization budget's name or definition. Empty list or `NotFoundException` is PASS; `AccessDenied` or any other error is FAIL (inconclusive). See Q12. |
| TC43 | AC10 | positive | TC41 and TC42 with the Offers Platform admin profile. | Same results: the trail is visible and owned by the management account; the organization budget is not in Offers Platform (budgets kept under requirement 7 are allowed). |
| TC44 | AC10 (req 6, review Q4) | negative | ABC Bank admin: `aws cloudtrail update-trail --name <org trail ARN> --enable-log-file-validation` (a no-op: same value as today). Afterwards, management admin repeats TC19 and TC21. | The call fails (any error); the trail is unchanged and still logging. Assumption, see Q4. |
| TC45 | AC10 (req 6, review Q4) | negative | `aws iam simulate-principal-policy` for the ABC Bank and Offers Platform administrator roles, with the trail bucket policy as resource policy and the management account as resource owner: `s3:DeleteObject`, `s3:DeleteObjectVersion`, `s3:PutObject`, `s3:PutBucketPolicy`, `s3:PutLifecycleConfiguration`, `s3:PutBucketVersioning`, `s3:GetObject` on the trail bucket. | All denied. Also real read-only calls from ABC Bank admin, `list-objects-v2` and `get-bucket-lifecycle-configuration` on the bucket: `AccessDenied`. |
| TC46 | AC10 (req 6) | regression | Management admin: `aws sso-admin list-account-assignments` for the management account. | Only the Administrator permission set is assigned there, so it is the only Identity Center role that can change the budget, monitor, trail or bucket. |
| TC47 | AC11 | positive | Offers Platform admin: `aws cloudtrail describe-trails` (no shadow trails) in every enabled region (`aws ec2 describe-regions`). For each trail owned by Offers Platform: `get-event-selectors`, `get-insight-selectors`. | No trail exists that records only management events (no data events, no Insights) and has no `CloudWatchLogsLogGroupArn` and no `SnsTopicARN`. A trail that is only stopped (not deleted) still counts as existing and is FAIL. |
| TC48 | AC11 | positive | `README.md` section for the Offers Platform findings. | Lists trails, budgets and anomaly monitors found in Offers Platform, each with what was done (removed, kept with the reason, or "none found" for a kind with nothing). |
| TC49 | AC11 | positive | Compare `op-trails.json`, `op-budgets.json`, `op-anomaly-monitors.json` (baseline) with `README.md`. | Every baseline item appears in README by name with an action. README lists nothing absent from the baseline. Baseline missing is FAIL. |
| TC50 | AC11 | regression | Compare baseline budgets, anomaly monitors and anomaly subscriptions in Offers Platform with live (`describe-budgets`, `get-anomaly-monitors`, `get-anomaly-subscriptions`). | All still exist, unchanged (requirement 7: keep any budget or monitor). |
| TC51 | AC11 | negative | For each baseline Offers Platform trail that records anything beyond management events, or has a CloudWatch Logs or SNS destination, or whose bucket is read (TC54's checks): live `describe-trails` and `get-trail-status`. | Still exists, unchanged, logging as before, and is listed in README as kept. Removing such a trail is FAIL. |
| TC52 | AC11 | positive | Each trail kept under requirement 7. | README states its monthly cost, and that cost is included in the AC13 figure (MANUAL check against the PR). No kept trail: nothing to check. |
| TC53 | AC11 (review Q5) | negative | Scan `README.md` and the committed diff for 12-digit numbers, email addresses, and ARNs or bucket names containing an account ID. | None found; commands use placeholders (for example `<offers-platform-account-id>`). Assumption, see Q5. |
| TC54 | AC11 (Nov 22 Q3 step 1) | negative | For each removed trail's old bucket (Offers Platform admin, read-only): `get-bucket-notification-configuration`; `s3control list-access-points --bucket`; `get-bucket-replication`; `get-bucket-policy` and `get-bucket-acl`; `aws glue get-tables` for every database (and `athena list-table-metadata` where used), looking for a location under the bucket. | No event or EventBridge notifications; `ReplicationConfigurationNotFoundError`; no access points; policy and ACL let only the CloudTrail service write and only the Offers Platform account read; no Glue or Athena table points at it. Any hit is FAIL (the trail should have been kept). |
| TC55 | AC11 (Nov 22 Q3 step 5) | regression | Offers Platform admin: `head-bucket` on each removed trail's old bucket; count its objects under the old trail's prefix. | Bucket still exists; its object count is not lower than at the copy (nothing deleted). |
| TC56 | AC11 (Nov 22 Q3 steps 2 and 3) | positive | List keys under the old trail's prefix in the old bucket (Offers Platform admin) and under `legacy/offers-platform-account-trail/` in the trail bucket (management admin), with pagination. | Object counts are equal, and the key sets match: for every source key `K` there is `legacy/offers-platform-account-trail/K` (key structure kept). Both log files and `CloudTrail-Digest` files are present in the copy, with equal counts of each. |
| TC57 | AC11 (Nov 22 Q3 step 2) | positive | `aws s3api get-object-tagging` on every object under `legacy/offers-platform-account-trail/`. | Every object has the tag `source = offers-platform-account-trail`. |
| TC58 | AC11 (Nov 22 Q3) | boundary | Stubbed listings: counts differ by one; equal counts but one key renamed; digest files missing; one object without the tag or with `source = offers-platform`. | AC11 prints FAIL in each. |
| TC59 | AC11 (Nov 22 Q3, review Q3) | boundary | No trail was removed (none found, or all kept). | `legacy/offers-platform-account-trail/` is empty and AC11's copy checks report "not applicable" and count as passed. Objects under the prefix when no trail was removed is FAIL. Assumption, see Q3. |
| TC60 | AC11 (Nov 22 Q3 step 4) | positive | `README.md`. | Contains steps 1 to 4 in order with their commands: the bucket reader checks, the copy (download with the Offers Platform admin, upload with the management admin, tag `source = offers-platform-account-trail`, prefix `legacy/offers-platform-account-trail/`), the count check, and `aws cloudtrail delete-trail`; says the old bucket is kept. |
| TC61 | AC11, AC14 (Nov 22 Q3 step 4) | negative | `terraform state list` and `terraform show -json` in `guardrails/`; grep `guardrails/*.tf` for provider aliases. | No Offers Platform trail resource in state; every resource ARN in state is in the management account; no provider configured for a member account. The deletion was manual, not Terraform. |
| TC62 | AC12 | positive | Read tags: `aws cloudtrail list-tags` (trail), `aws s3api get-bucket-tagging` (trail bucket), `aws budgets list-tags-for-resource` (budget ARN), `aws ce list-tags-for-resource` (monitor ARN). Cross-check the resource list with `terraform state list` in `guardrails/`. | Each has the four cost tags with the exact values. The imported monitor (TC14) has them too. |
| TC63 | AC12 | boundary | Stubbed tag sets: one tag missing; `environment=prod`; key `Owner`; extra unrelated tags present. | FAIL for the first three; extra tags alone are PASS. |
| TC64 | AC13 | positive (MANUAL) | Script prints MANUAL: check the PR states the expected monthly cost. Supporting evidence printed to stderr: current trail bucket size and object count (`aws s3 ls --summarize --recursive`, or CloudWatch `BucketSizeBytes`), the legacy prefix size, and the TC23/TC24 results. | PR states a figure under $2 per month, covering S3 storage for about 120 days with versioning, PUT requests, the budget, anomaly detection, any kept Offers Platform trail and the stored legacy copies. |
| TC65 | AC13 | boundary | A stated figure of exactly $2.00, or a figure that leaves out a kept trail or the legacy copy storage. | Not accepted (the story says "under $2"). See Q2. |
| TC66 | AC14 | positive | `terraform plan -detailed-exitcode -input=false` in `guardrails/`. | Exit 0. Exit 1 or 2 is FAIL. |
| TC67 | AC14 | positive | `terraform fmt -check -recursive`; `terraform validate` in `guardrails/`; `make test`; `make lint`. | All exit 0; `make test` validates `guardrails/` (it is in the Makefile's list of roots). |
| TC68 | – | regression | `terraform plan -detailed-exitcode` in `bootstrap/` and `organization/`. | Exit 0: FND-4 did not change the earlier roots. `guardrails/` uses its own state key, different from theirs. Printed as line `REG-TC68`. |
| TC69 | – | regression | `aws organizations list-aws-service-access-for-organization`; ABC Bank engineering profile `aws ce get-cost-and-usage` for the last 7 days. | `cloudtrail.amazonaws.com` still has trusted access; the member account still sees its own costs. Printed as line `REG-TC69`. |
| TC70 | – | regression | `aws organizations list-policies --filter SERVICE_CONTROL_POLICY` and `list-policies-for-target` on the root and each account; `aws sso-admin list-permission-sets` and `list-account-assignments` for all three accounts. | No new SCP (only `FullAWSAccess` if SCPs are enabled); the Administrator assignment still exists in all three accounts; permission sets unchanged in number and name. Printed as line `REG-TC70`. |
| TC71 | – | regression | `aws iam list-users` in the management and ABC Bank accounts; `aws iam list-access-keys`. | No IAM users and no access keys. Printed as line `REG-TC71`. |
| TC72 | – | regression | Repo hygiene: `git ls-files`; grep `guardrails/`. | No tracked `*.tfvars` except `example.tfvars` (which exists in `guardrails/` with placeholder email); no state or credentials; no 12-digit account IDs or email addresses in `.tf` files outside variable defaults; provider pinned to a version range; region `us-east-1`; every variable and output has a description. Printed as line `REG-TC72`. |
| TC73 | – | regression (MANUAL) | Run `tests/FND-3.sh` after FND-4 is applied. | No line that was PASS in the FND-3 PR evidence is now FAIL. |
| TC74 | – | regression | Run `tests/FND-4.sh` with one profile deliberately missing, and once with the baseline directory pointing at an empty path. | `set -euo pipefail`; exactly one PASS, FAIL or MANUAL line for each of AC1 to AC14 in order, then `REG-TC68` to `REG-TC72`; affected lines FAIL rather than aborting; exit 1 if any line is FAIL; the engineer's email never appears in output; the AC7 test bucket and scratch files are gone afterwards. |

Types: positive, negative, boundary, regression.

## Acceptance criteria coverage
| AC # | Criterion | Cases |
|------|-----------|-------|
| AC1 | One monthly $100 cost budget, alerts at 50/80/100% actual to the engineer | TC01, TC02, TC03, TC04 |
| AC2 | `working` posture plans only a $300 limit change; `lean` returns $100 | TC05, TC06, TC07, TC08 |
| AC3 | Test alert at $0.01 reaches the inbox, then reset with no plan changes (MANUAL) | TC09, TC10, TC11 |
| AC4 | Service monitor; daily email subscription at $10 (and the monitor-import decision) | TC12, TC13, TC14, TC15, TC16 |
| AC5 | Four cost-allocation tags active | TC17, TC18 |
| AC6 | Organization trail, all regions, validation on, read and write management events, logging | TC19, TC20, TC21, TC22, TC23, TC24, TC25, TC30 |
| AC7 | ABC Bank test bucket create and delete appear in the trail bucket within 30 minutes; bucket deleted | TC26, TC27, TC28, TC29 |
| AC8 | `validate-logs` for the previous hour reports valid files | TC31, TC32, TC33 |
| AC9 | Trail bucket: versioning, public block, encryption, 90-day and 30-day lifecycle (plus delete markers) | TC34, TC35, TC36, TC37, TC38, TC39, TC40 |
| AC10 | From ABC Bank: trail visible and owned by management; no organization budget there (plus member cannot change trail or bucket) | TC41, TC42, TC43, TC44, TC45, TC46 |
| AC11 | README lists Offers Platform findings; no management-only trail left there (plus the Nov 22 Q3 removal and copy procedure) | TC47, TC48, TC49, TC50, TC51, TC52, TC53, TC54, TC55, TC56, TC57, TC58, TC59, TC60, TC61 |
| AC12 | Trail, bucket, budget and monitor carry the four cost tags | TC62, TC63 |
| AC13 | PR records expected monthly cost under $2 (MANUAL) | TC23, TC24, TC64, TC65 |
| AC14 | No plan changes in `guardrails/`; fmt and validate pass | TC61, TC66, TC67 |
| – | Regression: earlier roots, trusted access and member Cost Explorer, no SCP or Identity Center change, no IAM users, repo hygiene, FND-3 checks, script behaviour | TC68, TC69, TC70, TC71, TC72, TC73, TC74 |

## Questions for the story

The five open questions from the story review (round 2) are known gaps. For
each, the plan states the assumption it tests against; the owner can change
it at the design gate.

- **Q1 (story review): existing anomaly monitors and subscriptions in the management account.** Interim assumption (design feedback round 1, conflict 2; owner to confirm at the gate): exactly one SERVICE monitor and exactly one subscription on it, the story's own (daily, $10, engineer's email), whether an existing one was imported and changed or replaced. A second SERVICE monitor (TC12, TC14) or a second subscription on the service monitor (TC15) is FAIL. Other monitors and subscriptions are listed in the PR and left alone, in line with requirement 7's "keep"; the tests check they are unchanged against the baseline. If the owner decides differently at the gate, TC12, TC14 and TC15 change to match.
- **Q2 (story review): cost over $2.** Assumption tested: $2 per month is a hard limit on the recurring total, which includes any trail kept in Offers Platform and the storage of the copied legacy logs. One-time copy request charges are reported separately in the PR and not counted. A total of $2.00 or more is not accepted (TC64, TC65); the implementer stops and brings it to the owner.
- **Q3 (story review): no criterion for the legacy copy.** Assumption tested: the Nov 22 Q3 procedure counts toward AC11's PASS (TC54 to TC61). If no trail was removed, the copy checks are "not applicable" and count as passed, and the legacy prefix must be empty (TC59).
- **Q4 (story review): no criterion for requirement 6.** Assumption tested: the delete-marker lifecycle rule counts toward AC9 (TC38), and the "member accounts cannot change the trail or the bucket" checks count toward AC10 (TC44, TC45, TC46). They test today's permissions only; no bucket-policy deny is expected (Nov 22 Q2 decision). The trail check is a no-op `update-trail` call, never `stop-logging` or `delete-trail`, so a wrong success changes nothing. Resolved for TC44 (design feedback round 1, item 1): the owner chose the no-op `update-trail` call; no test calls `stop-logging` or `delete-trail`.
- **Q5 (story review): what the public README may record.** Assumption tested: FND-3's README redaction rule applies. Trail, budget and monitor names may appear; account IDs, email addresses, and ARNs or bucket names containing an account ID are replaced with placeholders, including in the copy and delete commands (TC53). TC49 and TC60 compare names and command shapes, not IDs.

Questions raised by this plan:

- **Q6: baseline for requirement 7 and the import decision.** Resolved (design feedback round 1, item 4): the implementer takes the read-only snapshot before the `guardrails/` apply, in `${FND4_BASELINE_DIR:-$HOME/.fnd-4-baseline}` outside the repo, with the files named in the notes above. TC14, TC15, TC49, TC50 and TC51 read it; a missing baseline is FAIL.
- **Q7: how AC3 sets $0.01 "through Terraform".** The plan assumes a temporary variable override (`-var` or an untracked `.tfvars` entry), not a committed code change, so the reset leaves no diff and the plan shows no changes. Is that right?
- **Q8: who runs AC3, and when.** Resolved (design feedback round 1, conflict 7): AC3 is an owner step; the script only reports MANUAL (TC09, TC10), and TC11 checks the reset.
- **Q9: AC8 before two hours.** If the script runs less than two hours after logging starts, the plan prints MANUAL "rerun later" rather than FAIL (TC32). Acceptable?
- **Q10: posture values.** Resolved (design feedback round 1, item 3): the values are lowercase `lean` and `working`; anything else, including `Heavy`, an empty string and `Working`, is rejected by the variable (TC08).
- **Q11: "read and write management events".** Does excluding management event sources (for example KMS or RDS Data API events, often excluded to cut volume) still meet AC6? The plan assumes no exclusions (TC20).
- **Q12: AC10 "no organization budget" in ABC Bank.** ABC Bank stories may later add budgets of their own. The plan checks only that no budget with the organization budget's name or definition exists there (TC42). Is that the intended reading?
- **Q13: AC7's test bucket.** Resolved (design feedback round 1, conflict 7): the name is `fnd4-audit-test-<random>`; it is tagged with the four cost tags and deleted in a `trap` (TC26, TC28).
- **Q14: the anomaly subscription's tags.** AC12 names the trail, bucket, budget and monitor. The subscription is also taggable. Must it carry the cost tags? The plan does not require it.
- **Q15: legacy copies and validation.** CloudTrail digest files refer to their original bucket and keys, so `validate-logs` most likely cannot validate the copies under `legacy/`. The plan does not validate them (AC8 uses the trail's own logs only). The owner should confirm the copies are kept for history, not as tamper-evident records; the originals stay in the old bucket.
