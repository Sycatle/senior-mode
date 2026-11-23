---
id: 474
title: Agents iterate fast while senior-mode's quality rules grow
status: accepted
size: L
paths: ["plugins/senior-mode/bin/**", "plugins/senior-mode/hooks/**", "plugins/senior-mode/skills/brief/**", "plugins/senior-mode/skills/verify/**", "plugins/senior-mode/skills/run/**", "plugins/senior-mode/skills/next/**", "plugins/senior-mode/agents/**", "plugins/senior-mode/presets/**", "plugins/senior-mode/templates/**", "docs/guide/**"]
adrs: ["0028", "0006", "0007", "0017", "0018", "0022", "0027"]
issue: "#474"
---

# Agents iterate fast while senior-mode's quality rules grow

## 1. Goal and non-goals

Epics #471 (code rules) and #472 (performance) add many checks: lint packs, diff detections, coverage,
duplication, mutation testing, benchmarks, Lighthouse. Run as today, where `check` runs every check one after the
other before each push, they would turn a two-minute loop into a twenty-minute one, and an agent that waits
for its check is an agent that does not ship. The daemon runs around the clock, so there is no quiet night in
which to hide the slow work. The owner decisions of 2026-11-23 (ADR 0028) are fixed: this spec makes them
testable. It ships before #471 and #472: no rule lands without its tier.

Goals: every check declares a tier (§2); the edit tier fixes as the agent types (§3); the heavy tier runs
beside the review and gates only the merge (§4); lanes adapt the local work to the ticket's risk (§5); `check`
holds a 2-minute budget with a cache and compact output (§6 to §8); a new rule warns before it blocks (§9);
the agent knows the bar before it writes (§10); the orchestrator delegates with a checked brief (§11); the
retro shows what the rules cost (§12).

Non-goals:

- Lowering the merge bar. Every check runs on every pull request before it merges. Lanes and tiers change
  where and when a check runs, never whether it runs (ADR 0027: levers add, never lift).
- Changing who reviews or merges (ADR 0017, 0018, 0019).
- Writing the rules themselves. They come from #471 and #472.

Reused, not redone: per-check timing and `SENIOR_MODE_CHANGED_FILES` narrowing on pre-push (#231, `check`
in `bin/lib/check.sh`); the full log of a failed check (#294); token cost per ticket (#299); the project's
own CI jobs (#417); the affected set and the cache by tree (#418, spec 327 §4 and §10); slots (spec 327 §7).

## 2. Tiers

Each entry of `checks` in `.claude/senior-mode.json` may say when it runs:

```json
"checks": [
  { "name": "lint", "run": "pnpm lint", "tier": 2, "inputs": ["src/**", "eslint.config.*"], "fix": "pnpm lint --fix" },
  { "name": "mutation", "run": "pnpm stryker run --incremental", "tier": 3, "since": "2026-12-01" }
],
"check": { "edit": ["pnpm prettier --write {file}", "pnpm eslint --fix {file}"], "budget": 120, "warnDays": 14 }
```

- **Tier 1, edit.** `check.edit` lists fixers that run on one file, with `{file}` replaced by its quoted path.
  They are not checks: they never fail anything (§3).
- **Tier 2, push.** `check` and the pre-push hook run tier 2 checks, which is the default when `tier` is
  missing. Existing configurations therefore behave as today.
- **Tier 3, heavy.** Tier 3 checks run in the background from the push (§4). `check --tier 3` runs them in
  the foreground, and `check --all` runs tiers 2 and 3.
- The built-in secret scan and dependency audit are tier 2 and cannot be moved. A `tier` set on them is a
  configuration error.
- Presets give each command its tier: `e2e` is tier 3 in the node preset. The checks of #471 and #472 state
  their tier in their own spec.

Acceptance criteria:

- Given a check with no `tier`, then `check` runs it and `check --tier 3` does not.
- Given a check with `"tier": 3`, then `check` and the pre-push hook skip it and print
  `heavy: <name> runs after the push`; `check --tier 3` and `check --all` run it.
- Given `"tier": 4`, or a tier on the secret scan, then `check` fails with a configuration error naming the
  key.

## 3. Tier 1: fixed as it is written

A `PostToolUse` hook (`hooks/edit-fix.sh`, matcher `Edit|Write|MultiEdit`) runs the `check.edit` fixers on the
edited file when that file is inside the repository and is not ignored by git. Each fixer runs for at most
10 seconds and the hook for at most 15. The hook never blocks. Findings the fixers could not fix go back to
the agent as at most 10 lines, so it fixes them in the same step and does not discover them at push time.
With no `check.edit`, the hook does nothing.

- Given `check.edit` with a formatter, when the agent writes a badly formatted `src/a.ts`, then the file is
  formatted once the edit has run, and the hook exits 0.
- Given a fixer that reports an unfixable finding, then the agent receives `src/a.ts:12 no-unused-vars ...`
  (10 lines at most), and the edit is kept.
- Given a fixer that runs past 10 seconds, then it is killed, the hook says `edit-fix: <fixer> timed out`,
  and the hook exits 0.
- Given an edit to a file under `.gitignore` or outside the repository, then no fixer runs.

## 4. Tier 3: beside the review, before the merge

Tier 3 never makes an agent wait. Its result is one more commit status, `senior-mode/heavy`, required for
the merge only when the configuration has a tier 3 check or the lane deferred one (§5).

- **Start.** `publish` sets `senior-mode/heavy` to `pending` on the head and starts `check --tier 3 --publish
  <sha>` detached, in a worktree of the head under a slot (spec 327 §7). The log goes to
  `.git/senior-mode/heavy/<sha>.log`. A head that already has a heavy run gets no second one. When the
  project's CI covers a tier 3 check (`workflow.ci.jobs[].covers`, #417), its job is read instead of
  running the check again.
- **End.** The run sets the status to `success`, or to `failure` with the failing check names (140
  characters at most), and the compact lines of §8 are posted as one pull request comment marked
  `<!-- senior-mode:heavy -->`, which replaces the previous one.
- **Meanwhile.** The session reports `delivered` once `senior-mode/ci`, `senior-mode/review` and
  `senior-mode/security` are set, and moves on. The reviewer reviews in parallel.
- **Gate.** `run_blocker` also requires `senior-mode/heavy` to be green when it is required.
- **Failure.** A failure sends the pull request back the way a review that requests changes does:
  `serve` launches its fix session with the heavy comment as the findings, and the fix rounds count against
  the same limit. After a fix push, the new head gets its own heavy run. With `git range-diff` showing the
  same patches, the heavy status is carried over like the review status (spec 327 §4).
- **Merge train.** The tip of the train runs tier 3 only for the entries whose tree differs from the one
  that ran, using the cache by tree (§7).

- Given a tier 3 check, when `publish` runs on a pushed head, then `senior-mode/heavy` is `pending` at once,
  `publish` returns in less than 5 seconds, and later the status is `success` or `failure`.
- Given `senior-mode/heavy` pending or failed with every other status green, then `run_blocker` names
  `senior-mode/heavy not green` and nothing merges.
- Given a heavy failure on a pull request that `serve` drives, then a fix session starts with the heavy
  comment's lines, and the new head gets a new heavy run.
- Given no tier 3 check and no deferred check, then no heavy status is set and none is required.
- Given a rebase whose `git range-diff` is identical, then `senior-mode/heavy` is carried over and does not
  run again.

## 5. Lanes: as fast as the risk allows

A ticket has a lane, `fast` or `full`, which `start` computes and records (`.git/senior-mode/lane-<issue>`,
printed by `start` and by `context`):

- `full` when any of these holds:
  - the Size is M or L;
  - the Paths are empty;
  - a Paths glob overlaps a protected zone of the base branch;
  - a Paths glob overlaps `lanes.full` (globs the project declares for critical or hot code; #472 adds the
    hot paths of a spec).
- Otherwise, `fast`.

In the `fast` lane, the pre-push run narrows to the changed files as today, and tier 2 checks marked
`"lane": "full"` (e2e, the slowest suites) move to the heavy run. The merge bar is therefore unchanged:
every check runs before the merge, and the fast lane only spares the local wait.

The orchestrator may harden a lane, never lighten it. `senior-mode lane <issue> full` always works.
`senior-mode lane <issue> fast` on a computed `full` lane is refused with the rule that made it full. A
brief (§11) states the lane in its `## Constraints` section. Under `run` and `serve`, the prompt names the
lane.

- Given an S ticket whose Paths are `src/ui/**` and miss every protected zone and `lanes.full`, then `start`
  records `fast`. Given the same ticket with Paths `src/auth/**`, then `full`.
- Given a fast lane and an e2e check marked `"lane": "full"`, then the pre-push run skips it with
  `deferred: e2e (fast lane)`, and `senior-mode/heavy` is required and covers it.
- Given a computed `full` lane, when `senior-mode lane 12 fast` runs, then it fails naming the reason.
  Given `fast`, when `senior-mode lane 12 full` runs, then the lane becomes `full`.

## 6. Budget and timing

`check.budget` (seconds, default 120) is the wall-time budget of one tier 2 run. `check` already prints each
check's time. In addition, it:

- appends one line per check to `.git/senior-mode/check-times.jsonl`: time, branch, issue, tier, lane,
  check name, milliseconds, `ok`, `fail`, `warn` or `cached`;
- at the end, when the run went over budget, prints `warning: check took 3m10s, over the 2m budget; slowest:
  test (1m50s)`. Under `run` or `serve` it also files `perf(check): <name> is the slowest check over the
  budget` (Size S, `P2 later`, type task, label `check-budget`), whose body holds the last 5 times of that
  check.
- reuses an open issue of the same title, as `issue create` does, so the same slow check never opens two
  issues.

Cached checks count zero. A run with `--all` or `--tier 3` is not held to the budget.

- Given checks taking 100 and 50 seconds, then `check` passes, prints the over-budget warning naming the
  100-second check, and the times file has both lines.
- Given the same over-budget run under `serve` twice, then exactly one issue is open.
- Given `"budget": 300`, then a 150-second run prints no warning.

## 7. Cache by input tree

A tier 2 or tier 3 check that declares `inputs` (globs) is skipped when an earlier success had the same key.
The key is the hash of the check's name and command, the blob ids of the tracked files matching `inputs`,
the `.claude/senior-mode.json` blob and the lockfiles. Results live in `.git/senior-mode/cache/<key>`, so
every worktree of the repository shares them. This generalises the train cache and the package selection of
spec 327 (#418) to each check.

- Only successes are cached, and nothing is cached while a matching input has uncommitted changes.
- A check without `inputs` is never cached.
- `check --no-cache` runs everything.
- A run that hits the cache prints `ok    <name> (cached)`.

- Given a `lint` check with `inputs: ["src/**"]` that passed, when only `docs/a.md` changes, then the next
  `check` prints `lint (cached)` without running it. When `src/a.ts` changes, it runs.
- Given a failed `lint`, then the next run runs it again whatever changed.
- Given an uncommitted edit to `src/a.ts`, then `lint` runs and its result is not cached.
- Given a change to `eslint.config.js` listed in `inputs`, or to the lockfile, then the cache misses.

## 8. Compact output

On failure, `check` prints one line per finding, `<file>:<line> <check> <message>`, at most 10 lines. It
does so when the output has `file:line[:col]` lines (the format of compilers, ESLint compact, ruff, golangci-lint,
clippy short), followed by `fix: <command>` from the check's `fix` key when one is set, then the path of the
full log (#294). Output it cannot parse keeps today's last 20 lines. The heavy comment (§4) and the fix
session prompt use the same lines.

- Given an ESLint failure with 30 findings, then `check` prints 10 `file:line` lines, `… 20 more`, the `fix:`
  line and the log path, and no other output of that check.
- Given output with no `file:line`, then the last 20 lines are printed as today.

## 9. A new rule warns before it blocks

A check with `since` (a date, `YYYY-MM-DD`) only warns for `check.warnDays` days after that date (default 14,
in `.claude/senior-mode.json`). On the first day after the period, it blocks. While it warns:

- it prints `warn  <name>` with its compact lines;
- the result counts as passed, and the times file records `warn`, so the retro shows its false alarms.

The rules:

- `setup repo` writes `since` (today) on every check it adds to a configuration that already had checks. A
  new project starts blocking at once.
- A check without `since` blocks, as today.
- The built-in secret scan, the audit and the protected zones never warn: the safety base does not wait
  (ADR 0027).
- `.claude/senior-mode.json` is a protected path, so moving `since` forward is a human's change.

- Given `since` 3 days ago and `warnDays` 14, when the check fails, then `check` exits 0 and prints `warn`.
  On day 15, it exits 1.
- Given `since` on the secret scan, then `check` fails with a configuration error.
- Given `setup repo` adding the checks of a new preset version to an existing configuration, then each new
  check has `since` set to today, and existing ones are unchanged.

## 10. The bar before the first line

`senior-mode rules --paths <globs>` prints, in at most 40 lines:

- the checks whose `inputs` match the paths, or that have no `inputs`, each with its tier, `fix` and the
  `why` key when present;
- the `architecture.rules` that match (#337);
- the `review.sections` names;
- the shared-code map: the `## Shared code` section of the project's CLAUDE.md (#471), quoted.

`run_prompt`, `serve_prompt` and the batch prompts in `bin/lib/prompts.sh` include this digest for the
ticket's Paths, together with its lane. `start` prints it for an interactive ticket. An agent therefore
knows the bar before it writes, instead of learning it from a red check.

- Given Paths `src/ui/**` and a `lint` check with `inputs: ["src/**"]`, then `rules` lists `lint` with its
  tier and `fix`, and a `migrations` check with `inputs: ["db/**"]` is absent.
- Given a CLAUDE.md with `## Shared code`, then the digest quotes it. Without the section, the digest says
  `shared code: not mapped`.
- Given a run session, then its prompt contains the digest and the lane.

## 11. The orchestrator's brief

A skill `brief` teaches the orchestrator (Opus, in `next`, `run` and `serve` sessions) to delegate well. Its
template is mandatory for every call to the Agent tool. It has seven sections, in this order:

| Section | Holds |
|---|---|
| `## Goal` | One sentence: the outcome, not the steps |
| `## Context` | Ticket, spec, files and symbols to read, what was already tried |
| `## Constraints` | Lane, the rules digest (§10), protected zones, what must not change |
| `## Acceptance` | The criteria the work is judged on |
| `## Verify` | The exact commands to run and what they must show |
| `## Return` | The format of the answer: fields, length, `file:line` |
| `## Model` | The model chosen and why (ADR 0004, 0014) |

The skill gives a good and a bad example per agent type (implementer, test-author, reviewer, scout).

A `PreToolUse` hook (`hooks/brief-guard.sh`, matcher `Agent|Task`) reads `tool_input.prompt`. When the
repository has `.claude/senior-mode.json`, the hook refuses a call whose prompt lacks one of the seven
headings, or leaves a section empty (exit 2, the missing sections named, and a pointer to the skill).
Otherwise, it lets the call through and appends a line to `.git/senior-mode/briefs.jsonl`: time, session,
agent type, model, the `## Goal` line.

- Given an Agent call whose prompt has the seven headings, each followed by text, then it runs and
  `briefs.jsonl` has its line.
- Given a call missing `## Verify`, then the hook exits 2 with `brief: missing ## Verify (skill brief)`, and
  the subagent does not start.
- Given a repository without `.claude/senior-mode.json`, then the hook lets every call through.

## 12. What the rules cost, in the retro

`retro` adds a section `Iteration`, built from `check-times.jsonl`, `briefs.jsonl` and #299's token data:

- **Per ticket:**
  - round trips: the failing tier 2 runs on its branch before the first passing one;
  - time spent in `check`;
  - heavy failures;
  - lane;
  - tokens.
- **Per check:**
  - total time;
  - failures;
  - the share of round trips it caused;
  - warns during its period;
  - cache hit rate.
  The three costliest checks are named, each with a recommendation: cache it, narrow its `inputs`, move it
  to tier 3, or end its period.
- **Per agent type:** delegations and rework rate. A rework is a second call of the same type in the same
  session with the same `## Goal`.

`--json` gives the same data.

- Given a branch whose tier 2 run failed twice and then passed, then the ticket shows 2 round trips and both
  failing checks are counted.
- Given two implementer calls with the same Goal in one session, then the implementer's rework is 1 of 2.
- Given no times file, then the section says `no check history yet`.

## Delivery

The slices, in this order:

1. #476 tiers (§2) and #477 brief (§11), independent of each other.
2. #478 compact output (§8, after #294), #479 cache (§7), #480 budget (§6) and #481 warn period (§9).
3. #482 edit tier (§3) and #483 rules digest (§10).
4. #484 heavy tier (§4).
5. #485 lanes (§5).
6. #486 retro (§12, after #299).

Epics #471 and #472 are blocked by #476 (tiers), #481 (warn period) and #484 (heavy tier).

## Out of scope

- A remote cache shared between machines.
- Running checks inside the agent's editor, beyond the tier 1 hook.
- Choosing a model per lane: ADR 0014 stays.
- Dropping a check for a ticket. No lane removes a check from the merge bar.

## Test seams

- `check`, `publish`, `rules`, `lane`, `start` and `retro` (`bin/lib/check.sh`, `board.sh`, `status.sh`), through
  `bin/tests/test-check.sh`, `test-start.sh` and `test-retro.sh`, with fixture checks that sleep, fail or
  print `file:line` lines.
- `run_blocker`, and `serve`'s heavy and fix flow, through `test-run.sh` and `test-serve.sh` with the `gh` stub
  (statuses, comments).
- The two hooks through `hooks/tests/` with JSON inputs from `PostToolUse` and `PreToolUse`.
- The prompts, by asserting that `run_prompt` and `serve_prompt` contain the digest and the lane.
- Briefing quality through `evals/` with `claude -p` on the sandbox before merge (ADR 0011).

## Open questions

- Should `fork` subagents be exempt from the brief hook, since they inherit the conversation? Recommended:
  no. A fork still needs a Goal, a Verify and a Return, and the sections are cheap to write.
- The fixer and hook time limits (10 and 15 seconds) and `warnDays` 14 are starting values. Recommended:
  ship them as defaults, and read the retro after two weeks of the daemon.
- Should the budget ticket also be filed interactively? Recommended: no. A person sees the warning, and only
  headless runs file the ticket, so a local experiment does not file noise.
