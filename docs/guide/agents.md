# Agents

senior-mode ships eight agents, each with a narrow job, a pinned model and only the tools that job needs.

The main session routes work to them; it does not read code at length. The design is in
[spec §9](../specs/0001-senior-mode.md#9-agent-team) and [ADR 0004](../adr/0004-model-routing.md).

## The team

| Agent | Model / effort | Max turns | Tools | Preloaded skills | Job |
|---|---|---|---|---|---|
| `scout` | haiku / low | 15 | Read, Grep, Glob | none | Answer facts about the codebase with `path:line` |
| `researcher` | sonnet / medium | 25 | Read, Grep, Glob, WebSearch, WebFetch | none | Outside facts, comparisons, with sources |
| `architect` | opus / high | 40 | Read, Grep, Glob, Write, Edit | triage, spec, adr, grill | Alternatives, specs, ADRs, ticket splits |
| `test-author` | sonnet / medium | 30 | Read, Grep, Glob, Edit, Write, Bash | tdd | Failing tests from the acceptance criteria |
| `implementer` | sonnet / medium | 60 | Read, Grep, Glob, Edit, Write, Bash | tdd, commit, verify | Make the tests pass, refactor, commit |
| `reviewer` | opus / high | 30 | Read, Grep, Glob, Bash (no Edit, Write) | review, spec | Fresh-context review and merge verdict |
| `security` | opus / high | 30 | Read, Grep, Glob, Bash (no Edit, Write) | review | Security pass on protected zones and L tickets |
| `ops` | haiku / low | 20 | Bash, Read | commit | Issues, board fields, PRs, statuses, merges, releases |

Values come from each agent's frontmatter in `plugins/senior-mode/agents/`.

## Why these models

- **Haiku for mechanics.** Reading files to answer a factual question, or running `gh` commands,
  needs no judgement. The cheapest model does it.
- **Sonnet for most of the work.** Research, tests and code are the bulk of the tokens. Sonnet is
  the balance of cost and quality there.
- **Opus for decisions and verdicts.** Design choices and the merge verdict are where a mistake costs
  the most. The reviewer is never a cheaper model than the implementer.
- **Separate test author and implementer.** Tests written apart from the code are not bent to fit it.

## `scout`

Answers factual questions about the repository: where something lives, how it works, what a config
says. It changes nothing, says "not found" rather than guessing, and returns at most 20 lines.
Claude asks it before asking you anything the repository can answer.

## `researcher`

Collects verifiable facts outside the repository: official docs, changelogs, library comparisons.
Every claim has a source URL. It returns a comparison table and a one-line recommendation, and says
what it could not verify. Used during framing when an option depends on outside facts.

## `architect`

Designs before code. It compares at least two real alternatives for each hard-to-reverse choice,
writes the spec and ADRs, and splits work into vertical slices of size S or M with their blockers.
It writes only under `docs/` (by instruction; during `frame` a hook also enforces it). Its project
memory is a draft, not the record: `retro` promotes each entry to a [knowledge note](configuration.md#knowledge-notes)
or drops it.

## `test-author`

Turns acceptance criteria into failing tests, through the test seam the spec names, and checks they
fail for the right reason. A journey that lists records asserts the same query count for 1 and for 10 records through the [query-count helper](configuration.md#query-count-helper), so a list that queries once per record fails naming the expected and the actual count. It edits test files only (by instruction) and does not commit: the
implementer commits the tests with the code. For an M ticket, a separate session with
`SENIOR_MODE_ROLE=test-author` does commit them first; they are then read-only for the implementer
(see [Session roles](autonomy.md#session-roles)).

## `implementer`

Makes the failing tests pass with the simplest code, refactors, and commits atomically. It never
changes a test to make it pass. It runs `senior-mode check` before reporting. It stops and reports
when the work outgrows the ticket's size, or after two failed attempts at the same problem.

When it retried a step twice or more because of a constraint the code does not show, its pull request also
carries a [knowledge note](configuration.md#knowledge-notes) with `origin` set to its ticket: at most 2 notes
(the most useful), none without such a pitfall, and an existing note with the same `paths` and `kind` is edited
and re-verified instead of duplicated. `evals/knowledge/run.sh` measures it on a fixture ticket.

When it changes a skill or an agent for an improvement ticket from `retro`, its pull request carries a before/after
eval table made by `evals/compare.sh <case>` ([skill evals](autonomy.md#ready-pull-request)).

ADR 0004 plans a retry on Opus with high effort after two failed attempts. The agent stops as
planned, but the retry is the caller's job: `run` retries a failed ticket once on Opus
(`autonomy.escalate`, [ADR 0014](../adr/0014-model-escalation-in-runs.md)); in other sessions, ask
Claude to retry on Opus.

## `reviewer`

Judges a pull request it did not write, from an empty context. It reads the diff, the linked issue
and spec, and the tests, applies the [`review`](skills.md#review) skill, posts one comment and sets
the status `senior-mode/review`; it is the only role that may (`SENIOR_MODE_ROLE=reviewer`, see
[Session roles](autonomy.md#session-roles)). It cannot edit files. Its project memory (in `.claude/agent-memory/`,
git-ignored by `setup repo`: it stays on the machine) is a draft, not the record: `retro` reads it there and
promotes each entry to a [knowledge note](configuration.md#knowledge-notes) or drops it.

Each finding of its review ends with `<!-- finding: <slug> -->`, the slug stable for the same rule on the same
area. When a finding's slug is already on an earlier merged pull request that changed files under the same
directory, the reviewer opens a separate pull request `docs(knowledge): <slug>` with a `kind: pitfall`
[knowledge note](configuration.md#knowledge-notes) whose `origin` lists both pull requests (the reviewed pull
request and its branch are untouched); when a note already covers the finding, the review cites it and opens
nothing. A finding seen once opens nothing, and at most 2 such pull requests per review.

## `security`

The second review level ([ADR 0015](../adr/0015-security-posture.md)), for a pull request that
touches a [protected zone](autonomy.md#protected-zones) or closes a size L ticket. It starts from an
empty context, applies the Security section of the [`review`](skills.md#review) skill in depth,
following untrusted values into code the diff does not touch, posts one comment and sets
`senior-mode/security`: `success` with no high or critical finding, `failure` with one (and the
`needs-human` label), `pending` when it could not finish. It cannot edit files. It runs on Opus
because a miss costs most where it is used.

## `ops`

Runs bookkeeping with `gh`, `git` and the `senior-mode` script: tickets, board fields, labels, pull
requests, releases. It merges only with `gh pr merge <pr> --rebase --delete-branch`, only when told
to, only when `senior-mode/ci`, `senior-mode/review` and `senior-mode/security` are green, and never a `needs-human` pull
request. It skips `CLAUDE.md`, which it never needs.

## How they are used

- **Framing.** `frame` calls `scout`, `researcher`, `architect` and `ops`. Outside the commands, ask
  Claude by name, for example "use the reviewer agent on PR #43".
- **Delivery.** `next` chains `ops`, `test-author`, `implementer` and `reviewer` for each ticket with
  you in the loop; `run` uses the whole team without you.
