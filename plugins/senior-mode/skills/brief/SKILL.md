---
name: brief
description: Delegate with a checked brief of seven sections, so the subagent starts with the goal, the bar and the proof it owes. Use before every call to the Agent tool ("délègue", "lance un sous-agent", "brief").
---

# The brief

Every Agent call carries a prompt with these seven sections, in this order, none empty. The hook
`brief-guard.sh` refuses a call with no `## Goal` or no `## Verify` (`brief: missing ## Verify (skill brief)`);
a missing other section is only reminded. It logs the accepted calls to `.git/senior-mode/briefs.jsonl`.

| Section | Holds |
|---|---|
| `## Goal` | One sentence: the outcome, not the steps |
| `## Context` | Ticket, spec, files and symbols to read, what was already tried |
| `## Constraints` | Lane, the rules digest, protected zones, what must not change |
| `## Acceptance` | The criteria the work is judged on |
| `## Verify` | The exact commands to run and what they must show |
| `## Return` | The format of the answer: fields, length, `file:line` |
| `## Model` | The model chosen and why |

## Examples

Implementer
- Good: Goal "Make tests/test-ticket-12.sh pass"; Context "spec 40 §3, `bin/lib/check.sh:120`"; Verify
  "`senior-mode check` shows no FAIL"; Return "commit SHAs, one line each".
- Bad: "Implement #12."

Test author
- Good: Goal "Write the red tests of #12's three criteria"; Acceptance lists them; Verify "each test fails
  for the missing feature, not for a typo"; Return "test names and the red output".
- Bad: "Add some tests."

Reviewer
- Good: Goal "Review PR 31 against spec 40"; Verify "`gh pr diff 31`, then the tests of the criteria";
  Return "verdict, then findings as `file:line` + one sentence".
- Bad: "Look at my PR."

Scout
- Good: Goal "Find where the lane is computed"; Return "`file:line` per answer, 5 lines max"; Model "haiku,
  a lookup".
- Bad: "Explore the repo."
