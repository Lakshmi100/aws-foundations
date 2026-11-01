# Story review: <KEY> <summary>

Round <n> · <date>

## Gate

The orchestrator reads this block. Keep it valid JSON and keep the keys exactly.

```json
{
  "key": "<KEY>",
  "round": 1,
  "score": 0,
  "threshold": 80,
  "verdict": "READY | NEEDS_INFO",
  "blocking": ["B2"],
  "criteria": {"C1": 0, "C2": 0, "C3": 0, "C4": 0, "C5": 0, "C6": 0, "C7": 0, "C8": 0},
  "questions": 0
}
```

## Scores

| # | Criterion | Score | Max | Evidence (quoted from the story) | Gaps |
|---|-----------|-------|-----|----------------------------------|------|
| C1 | Intent and context | | 10 | | |
| C2 | Requirements | | 20 | | |
| C3 | Acceptance criteria | | 25 | | |
| C4 | Constraints | | 15 | | |
| C5 | Scope boundaries | | 10 | | |
| C6 | Dependencies and inputs | | 10 | | |
| C7 | Free of design | | 5 | | |
| C8 | Open questions resolved | | 5 | | |
| | **Total** | | **100** | | |

## Blocking issues
| # | Issue | Where in the story |
|---|-------|--------------------|

## Questions for the story owner
Ordered by points recovered, largest first.

| # | Resolves | Question | Why it matters |
|---|----------|----------|----------------|
| Q1 | C2 | | |

## Nice to know
Points that would not change the design, the tests or the delivery. No
points deducted; not counted in "questions".

## Design detail to confirm
Design choices found in the story. For each, keep it as a constraint (and add
the reason to the story) or remove it and leave it to the architect.

## Earlier questions
On a re-review: each earlier question and whether the story now answers it.
