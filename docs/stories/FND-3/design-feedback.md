# Design feedback: FND-3 (approval round 1)

From the story owner at the human gate, 2026-11-01. The owner approved the design and test plan subject to these resolutions; everything else stands as written.

1. **Checks beyond the criteria (AC6/AC7):** keep the test plan's extra checks (TC20, TC25, TC26, TC32, TC33, TC34). They count towards the criterion's PASS. The design's "check only what the ACs list" no longer applies.
2. **How a bounded role is identified:** go with the design. Bounded roles live under path `/eng/` plus the `iam:PermissionsBoundary` condition where IAM supports it; the tests use the role ARNs in design section 3.7 (this answers test-plan Q5).
3. **Customer-managed policies and the boundary policy (story review Q2):** accept the design's assumption. Neither engineering role gets `iam:CreatePolicy`, `CreatePolicyVersion` or `DeletePolicy`; edits to the boundary policy are explicitly denied. TC27 and the `iam:CreatePolicyVersion` part of TC34 become firm denied checks, not MANUAL.
4. **Cost tags (AC14):** all three accounts, including the management account, carry the four cost tags. Keep the test plan's tag checks (TC62, including the Identity Center instance and permission sets; a lock table only if one exists).

# Approval round 2

The owner approved the decisions added while applying round 1 (design revision 2):
1. Management account imported into `organization/` for tags only (D5), with the CLI tag step as fallback if the import shows unremovable changes.
2. Identity Center instance tagged once with a documented `aws sso-admin tag-resource` step; AC14 reads it back.
3. Owner takes the read-only Offers Platform baseline before the invitation, stored outside the repo (D7).
4. `tests/FND-3.sh` prints `REG-TC67` and `REG-TC68` after the 17 AC lines; either can fail the run.
5. TC69, TC70 and TC71 have no output line; they are reported as PR evidence.

# Implementation escalations (owner decisions)

1. **ABC Bank boundary size (6,097 of 6,144 characters):** a permissions boundary is a single managed policy and cannot be split. Accept it as is for FND-3; ABC-6 must choose a fallback (for example exact-match action wildcards) before it adds permissions to the ABC Bank engineering role.
2. **Recovery role (TC49, AC10):** add an explicit deny on `sts:AssumeRole` for `role/OrganizationAccountAccessRole` to the Offers Platform engineering role, and so to the Offers Platform boundary (the cap is built from the same statements). Not needed in ABC Bank: that role grants no `sts` actions. TC49 stays as approved.
3. **`offers_platform_account_email` variable:** accepted (the account resource requires an email).
