# Story review: FND-4 Cost and audit guardrails for the organization

Round 2 · 2026-11-22

## Gate

The orchestrator reads this block. Keep it valid JSON and keep the keys exactly.

```json
{
  "key": "FND-4",
  "round": 2,
  "score": 81,
  "threshold": 80,
  "verdict": "READY",
  "blocking": [],
  "criteria": {"C1": 10, "C2": 12, "C3": 17, "C4": 12, "C5": 10, "C6": 10, "C7": 5, "C8": 5},
  "questions": 5
}
```

## Scores

Checks done for this review (all read-only):
- `gh issue view 4`: open, labels include `approved`, no comments, last updated 2026-11-22T19:22Z. The body matches `story.md`. The only change since round 1 is three new "Nov 22, 2026" entries under "Decisions" (Q1, Q2, Q3).
- `organization/identity_center.tf`: the `Administrator` permission set is assigned to the Offers Platform account (`aws_ssoadmin_account_assignment.administrator`, `offers_platform = ...`). That confirms the "Offers Platform administrator role" the Q3 copy step depends on.
- Everything confirmed in round 1 still holds: FND-3 closed; CloudTrail trusted access and `feature_set = "ALL"` in `organization/main.tf`; Cost Explorer enabled (README step 7); ABC-4 and ABC-6 exist; the repo is public, and README's "Offers Platform IAM inventory" has its own redaction rule.
- I did not query AWS. Statements about AWS behaviour below are marked where I did not check them against current AWS docs.

| # | Criterion | Score | Max | Evidence (quoted from the story) | Gaps |
|---|-----------|-------|-----|----------------------------------|------|
| C1 | Intent and context | 10 | 10 | "As the engineer paying for this build, I want to be warned before spending passes my monthly limit, and to know who did what in every account..." The Context section cites roadmap §1, §4 and §6, and ABC-4 and ABC-6. | None. |
| C2 | Requirements | 12 | 20 | Round-1 gaps now closed. Q1: "if Cost Anomaly Detection already has a monitor in the management account, import it into Terraform rather than creating a second one." Q2: "requirement 6 describes today's permissions ... Nothing extra is enforced." Q3: a five-step procedure with a defined test for "reads" ("S3 event notifications or EventBridge notifications ... replication rule ... access point ... bucket policy or ACL ... Glue or Athena table"), the copy target ("`legacy/offers-platform-account-trail/`"), the check ("object counts match"), the method ("`aws cloudtrail delete-trail`, by hand, not in Terraform") and what happens to the old bucket ("kept as it is"). | (1) **Existing anomaly *subscription* in the management account (-4, new, a partial answer to round-1 Q1):** the decision covers the monitor only. Round-1 Q1 asked about "a monitor or subscription". AWS's automatic setup for new Cost Explorer users is believed to create a daily-summary subscription along with the AWS-services monitor, sent to the account's email (not checked against current AWS docs). The story doesn't say whether that subscription is imported and changed to req 3's address and $10 threshold, deleted, or left alone. If it's left alone, a second daily email may go to another address, and AC4 doesn't say how many subscriptions it expects. (2) **Cost beyond $2 (-4, round-1 Q4 still open, now wider):** "Keep any other trail" (req 7) and "its monthly cost counts toward the $2 limit" (AC11) still conflict if a kept trail costs more than $2 a month. The Q3 answer adds a second source of cost: the logs copied into the organization bucket are stored there for 90 days (about 120 with versioning), plus a one-time charge for the PUT and object-tagging requests. The Cost row ("S3 storage for 90 days of logs and the budget stay under $2 per month") doesn't mention either, and nothing says which wins if the total goes over $2. |
| C3 | Acceptance criteria | 17 | 25 | AC1 to AC14 are pass/fail with commands and expected values. AC11 now has a defined "nothing reads its bucket" test behind it (the Q3 decision). | (1) **No criterion for the legacy log copy (-4, new):** Q3 steps 2 and 3 are new requirements: objects under `legacy/offers-platform-account-trail/`, log and digest files with their key structure kept, every object tagged `source = offers-platform-account-trail`, and object counts that match the source. Steps 1–4 and their commands must also be written in README. No AC checks any of this. AC11 checks only that the trail is gone and that README lists the items. (2) **Req 6 has no criterion (-4, round-1 Q5 still open):** after Q2, req 6 still states a rule: only the management administrator role can change the trail and bucket, and expired delete markers are cleaned up. No AC checks either part. For example, nothing checks that `cloudtrail stop-logging` or `delete-trail` on the organization trail is denied from the ABC Bank administrator role, or that AC9 includes the delete-marker lifecycle rule. |
| C4 | Constraints | 12 | 15 | Every AGENTS.md item is in the Constraints table, as in round 1. Audit and member-account effects of the Q3 answer are stated: the copy goes under its own prefix in the organization bucket and follows its lifecycle; the Offers Platform trail is deleted by hand; the old bucket "is kept as it is". | **Personal data in the public `README.md` (-3, round-1 Q6 still open):** req 7 and AC11 put "everything found, and what was done with it" in README, and the Q3 decision adds "Steps 1–4 and the commands are written down in README". Commands for the copy and the deletion naturally contain bucket names, trail ARNs and account IDs. The story still doesn't say what may be recorded in this public repo. |
| C5 | Scope boundaries | 10 | 10 | The Out of scope list is unchanged. The decisions add two more boundaries: "A bucket policy that denies changes to everyone except the administrator role is a future enhancement (out of scope)" and "Deleting [the old bucket] is a later manual decision, outside this story." | None. |
| C6 | Dependencies and inputs | 10 | 10 | "FND-3 (#3): the organization (all features), the management account, CloudTrail trusted access, and `aws-foundations` Terraform state." The Q3 answer adds the Offers Platform and management administrator roles for the copy. | None. The Offers Platform Administrator assignment was confirmed in `organization/identity_center.tf`. |
| C7 | Free of design | 5 | 5 | The new "how" details come with reasons. The CLI download and upload: "This needs no cross-account bucket policy." The object tag: "so it is clear they came from the old Offers Platform trail." Deletion by hand: it's a one-off clean-up in a member account, which AGENTS.md lets the agent do only for resources the story names. | None deducted. See "Design detail to confirm". |
| C8 | Open questions resolved | 5 | 5 | "Open questions: None." The Q2 decision explains how req 6 is meant. The Q3 decision ("by hand, not in Terraform") is an explicit exception to req 8 ("Everything is defined in Terraform"), not a contradiction. | None. Req 8 now has to be read with that exception (see "Nice to know" 2). |
| | **Total** | **81** | **100** | | |

## Blocking issues
| # | Issue | Where in the story |
|---|-------|--------------------|
| - | None. **B1:** nothing unresolved. The Q2 and Q3 decisions are explicit, and the req 8 exception is stated. **B2:** every criterion can be tested as written. The gaps under C3 are missing criteria, not untestable ones. **B3:** FND-3 and both administrator assignments exist. **B4:** nothing forbidden. Deleting the duplicate trail is named by the story, the old bucket is kept, and no member-account resources are created. **B5:** not triggered. No Identity Center, permission-set or organization-policy change, and Q2 confirms that no bucket-policy deny is added. **B6:** met: "under $2 per month in total". The cost of the copy is asked under C2 rather than counted as an unstated recurring cost, because the story implies it falls under that limit. | |

## Questions for the story owner
Ordered by points recovered, largest first.

| # | Resolves | Question | Why it matters |
|---|----------|----------|----------------|
| Q1 | C2 | If the management account already has an anomaly **subscription** (for example a daily summary AWS created along with its default monitor), what happens to it? (a) Import it with the monitor and change it to req 3's address and $10 threshold; (b) delete it and create the story's own; (c) leave it and add a second one. | It decides whether Terraform imports one resource or two. It also decides how many subscriptions AC4 expects, and whether a second daily email keeps going to another address. |
| Q2 | C2 | If the monthly total goes over $2, which wins: keep the item and raise or exempt the limit for it, or stop and bring it back to you? This covers a trail kept under req 7, and the logs copied into the organization bucket (about 120 days of storage, plus one-time request charges). Should the one-time cost of the copy be reported in AC13's figure, or separately? | AC11 and AC13 can only pass or fail cleanly once this is known. Without it, the outcome depends on what is found in the account and how much old log history there is. |
| Q3 | C3 | Can an acceptance criterion check the Q3 copy? For example: under `legacy/offers-platform-account-trail/` the object count equals the source bucket's count, every object has the tag `source = offers-platform-account-trail`, and README contains steps 1–4 with their commands. If no duplicate trail was found, should the criterion print PASS ("not applicable") or MANUAL? | Steps 2 and 3 are new required behaviour with no test. The tester would otherwise have to invent the check, including the case where there is nothing to copy. |
| Q4 | C3 | Can an acceptance criterion check req 6 as it is now meant (today's permissions)? For example: from the ABC Bank administrator role, `cloudtrail stop-logging` and `delete-trail` on the organization trail are denied. And can AC9 also check the lifecycle rule that removes expired delete markers? (Round-1 Q5, unanswered.) | Nothing yet tests that a member account can't stop the trail or remove its logs, which is the point of req 6. The delete-marker rule is a stated requirement with no check. |
| Q5 | C4 | The repo is public. What may `README.md` record about the Offers Platform trails, budgets and monitors, and in the Q3 commands? For example: names only, or names with account IDs replaced by a placeholder; subscriber emails left out or shown as a label; bucket names and ARNs replaced. Or does FND-3's inventory redaction rule simply apply? (Round-1 Q6, unanswered, now wider because README must hold the commands.) | AGENTS.md keeps personal details and account IDs out of tracked files. The tester needs to know what AC11 compares against, and the reviewer needs to know what may be committed. |

## Nice to know
Points that would not change the design, the tests or the delivery. No
points deducted; not counted in "questions".

1. **Log validation of the copied logs.** CloudTrail digest files record the original bucket and object keys of the log files they sign, and each digest points to the previous one by its original location. So `aws cloudtrail validate-logs` most likely can't validate the copies under `legacy/...` (not checked against AWS docs). The originals stay provable, because the old bucket "is kept as it is". AC8 isn't affected: it validates the organization trail's own prefix, and the legacy prefix is separate. Tell the owner, so nobody assumes the copies are tamper-evident.
2. **Req 8 and the Q3 exception.** Req 8 says "Everything is defined in Terraform". The trail deletion and the copy are manual by decision. The architect should treat them as documented manual steps, not resources in `guardrails/`.
3. **Lifecycle for the copies.** Expiry counts from each object's creation date in the organization bucket, so "deleted 90 days after the copy" holds even for logs that were already old. Versioning then keeps them 30 more days as noncurrent versions.
4. **The object tag is not a cost tag.** `source = offers-platform-account-trail` is an S3 object tag. Cost allocation for S3 is per bucket, so it doesn't conflict with the four cost tags (AC12). Object tags are billed at a negligible per-tag rate.
5. **The upload into the trail bucket.** If the architect writes a trail bucket policy, it must not explicitly deny `PutObject` or `PutObjectTagging` to the management administrator role. Otherwise step 2 fails. Uploading the tagged copies at the same time (`--tagging` on the upload, or a later `put-object-tagging`) is an implementation detail.
6. **Who runs the manual steps.** The story says the steps are done "by hand" and written in README, but not whether the agent runs them with the administrator roles or the owner does. AGENTS.md lets the agent act on member-account resources the story names, so either works. Say so in the PR.
7. **Same-account readers.** The Q3 "reads" test covers bucket policies, ACLs, notifications, replication, access points and Glue/Athena. It doesn't cover IAM identity policies inside Offers Platform (for example the v1/v2 IAM users in FND-3's inventory). Round 1 found no CloudTrail references in `customer-spend-analytics`, and the old bucket is kept, so existing readers still see the old logs. Only new logs stop arriving.
8. Round-1 Nice to know items 1 to 10 still apply. In particular: use about 120 days of retention in the cost estimate, count PUT requests as well as storage, run AC3 early in a month, and add `guardrails/` to `make test` and `make lint`.

## Design detail to confirm
Design choices found in the story. For each, keep it as a constraint (and add
the reason to the story) or remove it and leave it to the architect.

- **Copy by CLI download and upload with two roles (Q3 step 2).** Reason given: no cross-account bucket policy is needed. Keep.
- **Prefix `legacy/offers-platform-account-trail/` and the object tag `source = offers-platform-account-trail` (Q3 step 2).** Reason given: it shows where the logs came from. Keep.
- **Trail deleted by hand with `aws cloudtrail delete-trail`, not in Terraform (Q3 step 4).** Reason implied: it's a one-off removal of a resource Terraform never managed. Keep.
- **Import an existing anomaly monitor instead of creating a second (Q1 decision).** This is a "what" with a reason (no duplicate monitor). Keep.
- Round-1 items (one posture variable, unblended cost, S3-managed encryption, trail bucket in the management account, per-service monitor, read and write management events, `guardrails/` root) are unchanged. Keep.

## Earlier questions
Round 1 (score 77, NEEDS_INFO):

| Round-1 # | Resolves | Status | Notes |
|-----------|----------|--------|-------|
| Q1 | C2 | Partly answered | The monitor will be imported (Nov 22 decision). The existing subscription is not covered, so it's asked again as round-2 Q1. |
| Q2 | C2 | Answered | Req 6 describes today's permissions; nothing is enforced; a deny bucket policy is out of scope. |
| Q3 | C2 | Answered | Five-step procedure: a defined "reads" check, a copy into the organization bucket, a count check, manual `delete-trail`, and the old bucket kept. It adds new gaps, asked as round-2 Q2 (cost of the copy) and Q3 (no criterion). |
| Q4 | C2 | Not answered | Carried forward as round-2 Q2, which now also covers the copy's cost. |
| Q5 | C3 | Not answered | Carried forward as round-2 Q4, reworded for req 6 as today's permissions. |
| Q6 | C4 | Not answered | Carried forward as round-2 Q5, which now also covers the commands README must hold. |
