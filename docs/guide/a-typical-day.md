# A typical day

A walk-through from an idea to a merged pull request, step by step, and which command runs each part.

`frame` and `next` run a whole flow. Without them, you ask Claude for each step in plain words, and
the skills, agents and hooks keep the work disciplined. The daily commands
`next` and `status` chain these steps with you; `run` does it without you.

## 1. Frame the idea

```
/senior-mode:frame show a warning when an invoice is overdue
```

- Claude sizes the idea (skill [`triage`](skills.md#triage)).
- The [`scout`](agents.md#scout) agent reads the repository; Claude reads your open issues and
  milestones. You are never asked what the code can answer.
- You answer short rounds of questions (skill [`grill`](skills.md#grill)). If an option depends on
  outside facts, the [`researcher`](agents.md#researcher) agent fetches them, with sources.
- The [`architect`](agents.md#architect) agent writes the spec and any ADRs, and splits the work into
  tickets of size S or M.
- You accept the spec and ADRs. A size L is never accepted without your explicit yes.
- The [`ops`](agents.md#ops) agent creates the tickets on the board, with size, priority, milestone,
  blockers and parent epic.
- Claude commits the documents on a branch `docs/<issue>-<slug>` and opens a pull request.

Claude ends with a short summary and suggestions you did not ask for.

## 2. Merge the documents

The documents pull request merges like any other (steps 5 to 7 below). Once it is merged, ask
Claude to check the tickets: the [`ready`](skills.md#ready) skill moves each one to `Ready`, or adds
`needs-info` with a comment listing what is missing and a recommended answer.

## 3. Start a ticket

Pick the top `Ready` ticket on the board and ask Claude to start it, for example "start #42", or let
`/senior-mode:next` do it. `senior-mode start 42` makes a worktree next to your checkout and a branch
named `<type>/<issue>-<slug>`, such as `feat/42-overdue-warning`, and moves the ticket to In progress.

On that branch, each new Claude Code session starts with the ticket's title, status, spec and
acceptance criteria (the `SessionStart` hook).

## 4. Tests first, then code

Ask Claude to deliver the ticket with the agent team:

- the [`test-author`](agents.md#test-author) writes failing tests from the acceptance criteria and
  keeps the failing output;
- the [`implementer`](agents.md#implementer) makes them pass, refactors, and commits. Tests go in the
  same commit as the code they cover, and each commit is a Conventional Commit (skills
  [`tdd`](skills.md#tdd) and [`commit`](skills.md#commit)).

Claude cannot end its turn with edits that were not verified: a hook asks it to run
`senior-mode check` and read the output first (skill [`verify`](skills.md#verify)).

## 5. Push and open the pull request

```
senior-mode check
git push -u origin feat/42-overdue-warning
gh pr create
senior-mode publish
```

- `senior-mode check` runs the check list and, on a clean tree, records the result for the commit.
- The `pre-push` git hook runs the same checks and stops the push if one fails.
- The pull request template starts with `Closes #42`, then "What this gives", "How it was verified"
  and "Technical detail".
- `senior-mode publish` sends the recorded result to GitHub as the status `senior-mode/ci`. In
  `actions` mode, the workflow sets it instead.

Claude runs these for you when you ask it to open the pull request.

## 6. Review from a fresh context

Ask Claude to review the pull request with the [`reviewer`](agents.md#reviewer) agent. It starts
from an empty context, reads the diff, the spec and the tests, and posts one comment with a verdict
on two axes (skill [`review`](skills.md#review)). It sets the status `senior-mode/review`:

| Verdict | Status |
|---|---|
| Approve | `success` |
| Approve, human merge (sensitive area) | `pending`, plus the `needs-human` label |
| Changes requested | `failure` |

After fixes, push, check, publish and review again.

## 7. Merge and release

When `senior-mode/ci` and `senior-mode/review` are green on an up-to-date branch, merge by rebase:

```
gh pr merge 43 --rebase --delete-branch
```

The ruleset refuses the merge until both statuses are green. `Closes #42` closes the ticket. The
spec says GitHub's built-in Project workflows set `Done` on merge; if your board does not, run
`senior-mode item set 42 Status Done`.

To publish a release from the merged commits:

```
senior-mode release --dry-run
senior-mode release
```

## Where the commands fit

| Step | Command |
|---|---|
| Read where things stand | `status`, a plain-language dashboard |
| Steps 3 to 7, with you in the loop | `/senior-mode:next` picks the top Ready ticket and delivers it with you |
| Steps 3 to 7, without you | `/senior-mode:run` delivers up to N Ready tickets, and merges within guardrails when you turn merging on; `senior-mode schedule install` runs it every day |
| Weekly cleanup | `/senior-mode:retro` gives the facts of the week and up to three process changes to approve |

Note: Claude's session greeting and the end of `frame` mention "go" and `/senior-mode:next`: "go"
starts `next`.
