# AWS Foundations: agent instructions

This repo holds the organization-wide AWS setup shared by every project: the
AWS Organization and its three accounts (Management + Shared Services, ABC
Bank, Offers Platform), IAM Identity Center and its permission sets, budgets
and cost anomaly alerts, cost-allocation tags, and the organization CloudTrail
trail. Everything here runs in, or is managed from, the management account.
Project-wide context (roadmap, business problem, ADRs) is in
https://github.com/Lakshmi100/offers-platform-workspace (`docs/`).

Pipeline rules (story workspace, git conventions, base definition of done)
are in `.claude/factory/RULES.md`.

## Stories

- Source: GitHub Issues in `Lakshmi100/aws-foundations`
- Key prefix: `FND` (issue #2 is `FND-2`)
- Every story is approved by a human (label `approved`) before `/story` runs.

## Story review

Readiness threshold: 80

Constraints every story in this repo must address, or state as not
applicable (the story reviewer scores these under C4):
- **Access and lock-out:** how people sign in after the change, and how the
  owner gets back in if Identity Center or a permission set breaks
  (management account root with MFA is the break-glass path).
- **Least privilege:** which roles gain or lose permissions, and that
  day-to-day roles cannot change the organization, billing or Identity Center.
- **No IAM users or long-lived keys** in any account.
- **Cost:** monthly cost of what the story adds. Resources here persist, so
  anything billed by the hour needs a reason.
- **Tagging:** taggable resources carry the four cost tags, with the values
  under "Coding standards".
- **Audit:** effect on the organization CloudTrail trail and its log bucket.
- **Effect on member accounts:** which accounts and existing roles the change
  reaches (ABC Bank, Offers Platform).

Extra blocking rules (fail the gate whatever the score):
- **B5:** the story changes Identity Center, permission sets or organization
  policies and does not say how access is checked afterwards and how to
  recover if it breaks.
- **B6:** the story adds a recurring cost and does not state it per month.

## Layout

| Path | What it holds |
|------|---------------|
| `README.md` | One-time manual steps (management account sign-up, root MFA) and the state bootstrap |
| `bootstrap/` | Terraform that creates this repo's state storage (applied once) |
| `organization/` | Organization, accounts, Identity Center, permission sets and assignments |
| `guardrails/` | Budgets, cost anomaly detection, cost-allocation tags, CloudTrail organization trail |
| `docs/` | Repo docs; `docs/stories/` is the factory's story workspace |

Folders are created by the first story that needs them. Each folder under
the root is its own Terraform root with its own state key.

## Reference pattern

None yet. FND-1 sets the pattern for Terraform roots, state configuration,
variables and tagging; later stories mirror it.

## Commands

Not set up yet. The first story must add a `Makefile` with:

    make test     # terraform validate for every Terraform root
    make lint     # terraform fmt -check -recursive

Test framework and locations: acceptance checks are AWS CLI or Terraform
commands run against the real accounts, written as scripts in `tests/`
(one script per story, named by story key, e.g. `tests/FND-1.sh`), each
printing PASS or FAIL per acceptance criterion. A criterion only a person can
check (for example, "the alert email arrived") prints MANUAL with what to
check; the evidence goes in the PR.

**Everything here is real AWS.** Tests read state; they never create
resources except where an acceptance criterion says so (for example, a test
bucket to prove an audit event is logged), and they delete anything they
create.

## Coding standards

- Terraform: `terraform fmt`; region `us-east-1`; variables and outputs
  documented; no hard-coded account IDs except in variables; providers
  pinned to a version range.
- Cost tags and their values: `data-product = aws-foundations`,
  `environment = shared`, `owner = Lakshmi100`,
  `cost-center = offers-platform-portfolio`.
- Account email addresses, alert email addresses and other personal details
  go in an untracked `.tfvars` file; an `example.tfvars` shows the shape.
- Shell test scripts use `set -euo pipefail` and print one PASS, FAIL or MANUAL line per
  acceptance criterion.

## Definition of done (additions)

- `terraform validate` and `terraform fmt -check` pass for every changed root.
- `terraform plan` shows no changes after apply.
- The story's `tests/<KEY>.sh` passes against the real accounts, and its
  output is in the PR.

## Boundaries (additions)

- Never delete or close an AWS account, never leave the organization, and
  never remove the last administrator assignment. Stop and ask the human.
- Never use, change or create credentials for the management account's root
  user. Steps that need root are written down for the human to do.
- Never commit `.tfvars` with real values, Terraform state, or credentials.
- Do not create NAT gateways, and do not create resources inside member
  accounts other than what the story names.
