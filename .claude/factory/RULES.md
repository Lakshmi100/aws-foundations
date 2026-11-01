# SDLC Factory: pipeline rules

These rules apply to every repo the factory is installed in. They cover how a
story moves through the pipeline. Everything specific to the repo (layout,
reference pattern, test and lint commands, coding style, extra boundaries)
lives in that repo's `AGENTS.md`. If the two disagree, `AGENTS.md` wins for
repo matters and this file wins for pipeline matters; say which you followed.

## Story key

Every story has a key `<PREFIX>-<n>`. `AGENTS.md` names the prefix and where
stories come from:

- **GitHub Issues:** `<n>` is the issue number, e.g. issue #4 in a repo with
  prefix `ABC` is `ABC-4`.
- **Jira:** the Jira key as is, e.g. `RETAIL-2`.

## Story workspace

Each story gets a folder `docs/stories/<KEY>/`:

| File                 | Written by    | Purpose                                     |
|----------------------|---------------|---------------------------------------------|
| story.md             | orchestrator  | The story as received, verbatim             |
| story-review.md      | story-reviewer| Completeness score, gate verdict, questions |
| design.md            | architect     | Analysis, contract, data model, risks       |
| test-plan.md         | tester (plan) | Independent test cases from the story alone |
| design-feedback.md   | human         | Feedback at the design gate (if any)        |
| review.md            | reviewer      | Verdict, traceability, rule checks          |
| run-log.md           | orchestrator  | Timestamped events, the raw metrics data    |

Templates are in `docs/stories/_templates/`.

## Readiness gate

A story goes to design only when the story reviewer scores it at or above
the threshold (80 unless `AGENTS.md` sets another) with no blocking issues,
or when the human explicitly overrides the gate. Overrides are logged in
run-log.md with the human's reason.

## Definition of done

1. Every acceptance criterion in the story has at least one test.
2. The test and lint commands in `AGENTS.md` both pass.
3. Code follows the coding standards `AGENTS.md` names; any `Style exception:`
   is listed in the PR.
4. No changes outside the areas the story names, unless the story says so.
5. PR opened using `.github/pull_request_template.md`, with every section filled in.
6. Anything extra the repo's `AGENTS.md` adds to this list.

## Git conventions (these feed the factory metrics, so follow them exactly)

- Branch: `<KEY>-short-description`, e.g. `ABC-4-customers-table`
- PR title: `<KEY>: <story summary>`
- Every commit message ends with these trailers:

      Story: <KEY>
      Agent: <tool>/<role>     e.g. claude-code/implementer

  Keep every trailer, including any `Co-Authored-By:` line, in one block at
  the very end of the message, with no blank line between them. Git only
  reads the last paragraph as trailers, so a blank line inside the block
  hides `Story:` and `Agent:` from the metrics. Check a commit with
  `git log -1 --format='%(trailers:key=Story,valueonly) %(trailers:key=Agent,valueonly)'`.

## Boundaries

- Never push to the default branch. Never force-push.
- Do not edit `.github/workflows`, `.claude/`, lint configuration, or
  `AGENTS.md` unless the story asks.
- Do not add dependencies without listing them in the PR.
- If a story is ambiguous or contradicts `AGENTS.md`, do not guess silently.
  State the question and the assumption you made under "Open questions" in the PR.
