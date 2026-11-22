# Story review: FND-3 AWS organization, accounts and Identity Center access

Round 2 · 2026-11-01

## Gate

The orchestrator reads this block. Keep it valid JSON and keep the keys exactly.

```json
{
  "key": "FND-3",
  "round": 2,
  "score": 85,
  "threshold": 80,
  "verdict": "READY",
  "blocking": [],
  "criteria": {"C1": 10, "C2": 12, "C3": 21, "C4": 12, "C5": 10, "C6": 10, "C7": 5, "C8": 5},
  "questions": 4
}
```

## Scores

Checks done for this review (all read-only):
- `gh issue view 3`: the issue is open, still has the `approved` label after the update (updated 2026-11-02T01:25Z), and has no comments.
- `gh repo view`: `Lakshmi100/aws-foundations` is **public**. This matters for the `README.md` inventory (C4).
- `gh issue view` on FND-4 (#4) and ABC-3 to ABC-6 (Lakshmi100/abc-bank #3 to #6): all exist and are open. ABC-3 AC7a and ABC-4 AC3, which the out-of-scope list cites, exist and say what the story says they do. ABC-6's "Depends on" lists the same engineering-role abilities as requirement 4 (`rds-db:connect`, access path, Cost Explorer, Tagging API, read-only IAM). ABC-4 AC4f relies on the boundary denying direct key use, which requirement 5 states.
- ABC-4 requirement 1 still says "an alias that names its purpose", and ABC-3 gives no bucket name. Neither issue mentions `abc-bank-kms-key` or `abc-bank-offers-platform` yet (see "Nice to know" 1).

| # | Criterion | Score | Max | Evidence (quoted from the story) | Gaps |
|---|-----------|-------|-----|----------------------------------|------|
| C1 | Intent and context | 10 | 10 | "As the engineer building the Offers Platform ... so that every later story has an account to build in and a way for people and tools to get into it without long-lived keys". Context cites `docs/00-roadmap.md` §1 and §4 and now explains the state of the Offers Platform account ("IAM users and access keys in use today, most likely by laptop tools"). | None. |
| C2 | Requirements | 12 | 20 | Round 1 gaps are closed. Req 5: "capped to the engineering role's own permissions ... so any role it creates must carry the same boundary too". Req 4: "alias `abc-bank-kms-key`", "`abc-bank-offers-platform`", "IAM in read-only form", "Updating includes attaching, detaching, adding and removing policies (managed and inline) on roles that carry the boundary", "Billing and cost **reads** are not denied". Req 6: "inventory only ... Nothing is deactivated or deleted". Req 9: "everything is defined in Terraform in `aws-foundations`, except steps AWS only allows by hand". | (1) **First apply has no credentials (-4):** the management account starts empty ("signing up the management account"), there are no IAM users (req 6, AC9), there are no root access keys (AC9), and AGENTS.md says the agent never uses root ("Steps that need root are written down for the human to do"). Identity Center, the only other way in, needs the organization to exist first. Req 9 makes creating the organization a Terraform step, but nothing says who runs `bootstrap/` and the first `organization/` apply, or with what credentials. (2) **Customer-managed policies and the boundary policy itself (-4):** for both engineering roles the story covers roles and instance profiles, but not customer-managed IAM policies (`iam:CreatePolicy`, `iam:CreatePolicyVersion`, `iam:DeletePolicy`). For ABC Bank, "create, update and delete IAM roles" doesn't say whether "update" includes policy and trust changes, as it now does for Offers Platform. Nothing says the engineering roles cannot edit or delete the boundary policy itself. Req 5's "changing or removing permissions boundaries" is in the boundary, which covers roles the engineering roles create, not the engineering roles themselves. If either engineering role can create a new version of the boundary policy, it can widen every bounded role, and then the cap and the KMS deny no longer hold. |
| C3 | Acceptance criteria | 21 | 25 | AC7b now covers the boundary in both accounts, and the round 1 AC7a is gone. AC6 adds `kms:ScheduleKeyDeletion` and `kms:PutKeyPolicy`. AC8 covers the inventory. Every criterion is pass/fail, and the MANUAL ones say what to check. | **Req 4 (Offers Platform engineering) round 1 additions have no criterion (-4):** AC7 does not check IAM read-only allowed (for example `iam:GetRole`), policy changes on a bounded role allowed (`iam:PutRolePolicy`, `iam:AttachRolePolicy`), policy or trust changes on a role *without* the boundary denied (for example `iam:AttachRolePolicy` or `iam:UpdateAssumeRolePolicy` on `OrganizationAccountAccessRole`), or billing reads allowed (`ce:GetCostAndUsage`, `budgets:ViewBudget`). The denial on unbounded roles matters most. Changing `OrganizationAccountAccessRole`'s trust or policies would give a day-to-day role administrator rights, and nothing tests that this is denied. AC6 has the same hole for the ABC Bank engineering role. |
| C4 | Constraints | 12 | 15 | The Constraints table covers access and lock-out, least privilege, no IAM users (with a stated exception: "the v1/v2 tools depend on them and v1/v2 is out of scope"), personal data, cost ("under $0.50 per month"), tagging, audit, effect on member accounts ("its existing v1/v2 IAM roles are not changed"), and region. | **Security and personal data of the inventory (-3):** req 6 and AC8 put every Offers Platform IAM user, access key, key last-used data and v1/v2 role into `README.md`. This repo is public. IAM user names may be personal names, access key IDs identify live keys, and role ARNs contain the account ID (AGENTS.md: "no hard-coded account IDs except in variables"; "personal details go in an untracked `.tfvars` file"). The Personal data row covers state and `.tfvars` but not this file. |
| C5 | Scope boundaries | 10 | 10 | Out of scope now says "Any change to `customer-spend-analytics` (the v1/v2 code, its Terraform, its IAM roles) or to the credentials its tools use", "Attaching the permissions boundary to existing v1/v2 IAM roles" and "Replacing and removing the Offers Platform account's IAM users and access keys ... (a later story)". | None. |
| C6 | Dependencies and inputs | 10 | 10 | "None in other stories. The manual steps in requirement 9 are part of this story and done by the owner." Since v1/v2 is no longer touched, the `customer-spend-analytics` repo is no longer a dependency. The Offers Platform account is read for the inventory and joins the organization through req 9's manual step. | None. All cited stories and criteria were confirmed to exist. The naming contract with ABC-3 and ABC-4 runs downstream and does not change this story's design; see "Nice to know" 1. |
| C7 | Free of design | 5 | 5 | The design details all come with a reason: `PowerUserAccess` (Decisions), explicit denies ("Because `PowerUserAccess` itself allows Identity Center and billing actions"), the fixed key alias and bucket name (a contract with ABC-3 and ABC-4), `simulate-custom-policy` ("so no test role is created"), and the capped boundary (Decisions, after round 1). | None deducted. See "Design detail to confirm". |
| C8 | Open questions resolved | 5 | 5 | "Open questions: None." The issue kept the `approved` label after the update, which confirms the "Proposed defaults". The superseded decisions are struck through and replaced, so they don't contradict the requirements. | None. |
| | **Total** | **85** | **100** | | |

## Blocking issues
| # | Issue | Where in the story |
|---|-------|--------------------|
| - | None. **B1:** none open; the superseded decisions are struck through. **B2:** every criterion is testable. **B3:** every cited story exists. **B4:** the story creates no IAM users or keys, and the existing Offers Platform users are kept as a stated exception with a reason. **B5** is met: access is checked by AC3, AC4 and AC10, and recovery is covered by req 7, AC10 and AC11. **B6** is met: "under $0.50 per month" (Constraints, AC15). | |

## Questions for the story owner
Ordered by points recovered, largest first. The story is above the threshold, so these are not needed to pass the gate. Each one still removes a guess the architect or tester would otherwise make.

| # | Resolves | Question | Why it matters |
|---|----------|----------|----------------|
| Q1 | C2 | Who runs the first `bootstrap/` and `organization/` applies in the empty management account, and with what credentials, given there are no IAM users, no root access keys, and the agent never uses root? Realistic options: (a) the owner runs them as root in CloudShell (session credentials, no keys); (b) the owner creates the organization and enables Identity Center by hand, and Terraform imports them; (c) a temporary IAM user, deleted before AC9 is checked (this conflicts with AGENTS.md's "No IAM users"). | It decides the order of manual and Terraform steps in `README.md`, whether the implementer can apply anything before the owner acts, and whether req 9's "everything is defined in Terraform" holds for the organization itself. |
| Q2 | C2 | May the engineering roles create and change customer-managed IAM policies (`iam:CreatePolicy`, `iam:CreatePolicyVersion`, `iam:DeletePolicy`)? Must both roles be unable to edit or delete the permissions boundary policy itself? For ABC Bank engineering, does "update" include policy and trust changes on bounded roles, as it does for Offers Platform? | If the boundary policy can be rewritten by the roles it is meant to hold, the cap and the KMS deny that ABC-4 relies on no longer hold. The answer also decides whether ABC-6's session Terraform can attach policies to its instance roles. |
| Q3 | C3 | Can AC7 (and AC6 where it applies) check the round 1 additions? For example: `iam:GetRole`, and `iam:PutRolePolicy`/`iam:AttachRolePolicy` on a bounded role, **allowed**; `iam:AttachRolePolicy` and `iam:UpdateAssumeRolePolicy` on `OrganizationAccountAccessRole` (an unbounded role), **denied**; `ce:GetCostAndUsage` and `budgets:ViewBudget`, **allowed**. | Without these checks, nothing tests that a day-to-day role can't take over the recovery role, and nothing tests the reads that req 4 now promises. |
| Q4 | C4 | This repo is public. What may the `README.md` inventory contain? For example: IAM user names (or only a count and a label per user), access key IDs (full, last 4 characters, or none), and role names rather than ARNs with the account ID. Or should the inventory go somewhere untracked instead? | AGENTS.md keeps account IDs and personal details out of tracked files. The tester needs to know what AC8 compares against, and the reviewer needs to know what is allowed in the PR. |

## Nice to know
Points that would not change the design, the tests or the delivery. No
points deducted; not counted in "questions".

1. The decision that "ABC-4 and ABC-3 create them under these names" isn't in those issues yet. ABC-4 requirement 1 still says "an alias that names its purpose", and ABC-3 gives no bucket name. Updating both issues to name `abc-bank-kms-key` and `abc-bank-offers-platform` would stop their architects picking different names.
2. The Decisions section still says "**Proposed defaults, for the approver to confirm**". The approved label confirms them. Rewording them would stop later readers treating them as open.
3. AGENTS.md says "No IAM users or long-lived keys in any account". The Offers Platform exception has a reason in the story, but the code reviewer may still flag it. Mentioning it in the PR would avoid that.
4. AGENTS.md says "FND-1 sets the pattern" and "The first story must add a `Makefile`". This story was draft FND-1, so the architect should treat FND-3 as that first story (`Makefile`, `tests/FND-3.sh`).
5. AC7b gives an example "action that engineering role cannot do" only for ABC Bank (`ec2:CreateVpc`). The tester will need to pick one for Offers Platform, for example `iam:CreateOpenIDConnectProvider`.
6. AC5 doesn't check `iam:PassRole` allowed for a bounded role, or `ec2-instance-connect:OpenTunnel` for the EC2 Instance Connect Endpoint access path.
7. A member account's Cost Explorer access depends on a Cost Management preference in the management account (not checked against current AWS docs). AC5's real `ce get-cost-and-usage` from ABC Bank, and the v1/v2 Makefile's cost commands in Offers Platform, may depend on it.
8. For member-account root users, AWS's centralized root access management (removing member root credentials) might replace "setting MFA on the member accounts' root users". I have not checked whether this fits AC9's MFA check.
9. Carried over from round 1: accounts on AWS's newer Free plan may need to upgrade before joining an organization (not checked). The Offers Platform account isn't confirmed to be outside another organization. The default permission-set session of 1 hour normally covers Terraform runs. SSE-S3 or the AWS-managed key fits the state bucket's "under $0.50" (a customer-managed key costs $1 per month).
10. The header's "Readiness: 87/100 READY" refers to the draft's review in `offers-platform-workspace`, not this gate.

## Design detail to confirm
Design choices found in the story. For each, keep it as a constraint (and add
the reason to the story) or remove it and leave it to the architect.

- Offers Platform engineering role "Based on AWS's `PowerUserAccess`" with explicit denies. A reason is given. Keep.
- A permissions boundary capped to the creating engineering role's permissions (req 5). The owner chose this after round 1, and ABC-4 relies on it. Keep.
- Fixed names `abc-bank-kms-key` and `abc-bank-offers-platform`. These are a contract with ABC-4 and ABC-3. Keep, and carry it into those issues.
- `OrganizationAccountAccessRole` as the member-account recovery path, created by this story in the invited account (req 7). This is the AWS convention, and ABC-3 and ABC-4 rely on the name. Keep.
- Moving the bootstrap's own state into the bucket it creates (req 10). The reason is implied by AGENTS.md (no state committed), and ABC-3 uses the same pattern. Keep.
- Denials checked with `simulate-principal-policy`, and boundary checks with `simulate-custom-policy`, "never the real call". This is a safety constraint for real accounts. Keep.
- The access path "Systems Manager Session Manager sessions, or EC2 Instance Connect Endpoint tunnels". ABC-6 also says "Session Manager or EC2 Instance Connect Endpoint". Confirm that the role must allow both.

## Earlier questions
On a re-review: each earlier question and whether the story now answers it.

| Round 1 | Resolves | Status |
|---------|----------|--------|
| Q1 | C5 | **Answered.** Any change to `customer-spend-analytics` is out of scope, and existing v1/v2 roles get no boundary. |
| Q2 | C6 | **Answered (moot).** v1/v2 is no longer touched, so its repo is no longer a dependency. |
| Q3 | C3 | **Answered (moot).** AC7a was removed along with the v1/v2 switch-over. |
| Q4 | C2 | **Answered.** Option (c): the boundary is capped to the engineering role's own permissions, and bounded roles must carry it on roles they create. A related gap about editing the boundary policy itself is new in round 2 (Q2). |
| Q5 | C2 | **Answered.** Alias `abc-bank-kms-key` and bucket `abc-bank-offers-platform`; req 5 says it is "the same key as in requirement 4". |
| Q6 | C2 | **Answered.** Inventory only. Nothing is deactivated or deleted in this story. |
| Q7 | C2 | **Answered.** IAM read-only; "updating" includes managed and inline policies on bounded roles; billing and cost reads are not denied. No criterion checks these yet (round 2 Q3). |
| Q8 | C3 | **Answered (declined).** Decisions: "The manual steps in requirement 9 are checked by the owner by hand; they have no acceptance criterion." Their effects are covered by AC1, AC2, AC3, AC9 and AC12, so no points were deducted. |
| Q9 | C3 | **Answered.** AC7b checks that the boundary exists in both accounts and the full deny list, including the cap. |
