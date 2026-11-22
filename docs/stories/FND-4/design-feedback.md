# Design feedback: FND-4

## Round 1 (2026-11-22)

Owner's decisions on the conflicts between design.md and test-plan.md:

1. **Member-account change check (req 6):** use the test plan's no-op `update-trail` call from ABC Bank (TC44). Do not call `stop-logging` or `delete-trail` from any test. Drop the design's real `stop-logging` check.
3. **Posture values:** "use posture values". The orchestrator reads this as the design's lowercase values `lean` and `working`. The test plan's cases use these values: TC05 uses `working`; TC08 checks that other values (`Heavy`, an empty string, `Working` with a capital) are rejected.
4. **Baseline snapshot:** the implementer takes the read-only snapshot before the guardrails apply, in `${FND4_BASELINE_DIR:-$HOME/.fnd-4-baseline}` outside the repo (test plan Q6). The design's step I1 produces the snapshot files the test plan names, as well as the redacted README inventory.
5. **Output lines:** use the test plan's format. There is one line per criterion, AC1 to AC14. Requirement-6 checks count toward AC9 and AC10, and the legacy copy checks toward AC11. Then come `REG-TC68` to `REG-TC72`. There are no `X-REQ6` or `X-LEGACY` lines.
6. **Checking the legacy copy:** use the test plan's more thorough version:
   - key sets match, not just counts;
   - digest files are present, with counts equal by type;
   - every copied object has the tag;
   - the old bucket's object count has not dropped.
   This is TC54–TC59.

Not addressed by the owner. These are left for the owner to confirm at the gate:
- **Conflict 2, other anomaly monitors and subscriptions:** the design leaves monitors and subscriptions not on the service monitor alone. The test plan fails on any second subscription and wants exactly one monitor. Interim assumption: the test plan fails only on a second service monitor or a second subscription on the service monitor. Others are listed in the PR and left alone, which matches design open question 7 and requirement 7's "keep".
- **Conflict 7, small items:**
  - the AC7 test bucket name: use the test plan's `fnd4-audit-test-<random>`;
  - AC3 is an owner step that the script reports as MANUAL.
