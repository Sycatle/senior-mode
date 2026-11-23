---
id: 0028
title: Checks run in three tiers, and lanes adapt the local work to the risk, never the merge bar
status: accepted
spec: 474
---

## Context

`check` runs every configured check in sequence before each push (ADR 0006), and the session waits for it.
Epics #471 (code rules) and #472 (performance) will add lint packs, diff detections, coverage, duplication,
mutation testing, benchmarks and Lighthouse. Run that way, they would make every push wait many minutes,
and an autonomous daemon that works around the clock has no night in which to hide slow work. The owner
wants quality rules that never slow the agents: quality and speed together, not one traded for the other.

## Decision (owner, 2026-11-23)

- **Three tiers, declared per check.**
  - Tier 1 formats and fixes the edited file right after each edit. It never blocks.
  - Tier 2 is `check` before the push, narrowed to what changed, within a 2-minute budget (`check.budget`).
  - Tier 3 holds the heavy checks.

  A check without a tier is tier 2, so existing projects change nothing.
- **Tier 3 runs beside the review, from the push.** It reports one more commit status,
  `senior-mode/heavy`. That status gates the merge, never the agent: the agent moves on to its next ticket.
  A heavy failure sends the pull request back to its fix session, as requested changes do.
- **Lanes, computed and only hardened.**
  - `start` gives a ticket the `fast` lane when it is size S, has Paths, and touches no protected zone and
    no code the project marks critical. Every other ticket gets the `full` lane.
  - The fast lane moves the slowest tier 2 checks to the heavy run, which spares the local wait.
  - The orchestrator may harden a lane in its brief, never lighten it.
  - Every check still runs before the merge: the merge bar is the same for every ticket.
- **Speed tools inside `check`.**
  - A per-check cache keyed by the check's input files.
  - Compact output: one `file:line` line per finding, the fix command, the path of the full log.
  - Per-check timing kept in a history.
  - A ticket for the slowest check when a run goes over budget.
- **New rules warn first.** A check with `since` only warns for `check.warnDays` days (default 14), then
  blocks. The safety base (secret scan, audit, protected zones) never warns.
- **The bar is known before the first line.** Session prompts carry a digest of the rules that apply to the
  ticket's Paths and the project's map of shared code.
- **Delegation is checked.** A `brief` skill gives the orchestrator a mandatory template for every
  delegation: goal, context, constraints, acceptance, verification, return format, model. A hook refuses an
  Agent call that lacks a section.
- **The cost is measured.** The retro reports round trips per ticket, time in `check`, the costliest checks
  and rework per agent type.

## Alternatives

- **Everything in `check`, one tier.** It is the simplest, and it is as slow as the slowest check. Mutation
  testing and Lighthouse alone would end fast iteration.
- **Heavy checks before the review.** The review would only ever see a fully green pull request. Every pull
  request would wait for the heavy run first, and with the daemon around the clock that wait adds up.
- **Heavy checks after the merge, with an auto revert (#312).** It is the fastest, but unverified code
  reaches main. That contradicts the same-bar rule and ADR 0018's merge policy.
- **Severity by ticket size, letting small tickets skip checks.** It would be faster still, but it lowers
  the bar exactly where nobody looks, and ADR 0027 says levers add and never lift.
- **Brief guidance without a hook.** It costs nothing to enforce, and it is ignored under pressure: the
  owner wants the template enforced.

## Consequences

- Agents push in seconds to minutes. Heavy results arrive while the review runs, so a pull request can
  pass review and still be sent back by `senior-mode/heavy`.
- One more required status. A project with no tier 3 check and no fast-lane deferral never sees it.
- Background heavy runs use slots and machine time while the next ticket is already running.
  `autonomy.parallel` and the slots (spec 327 §7) bound them.
- The cache adds state under `.git/senior-mode/cache`. A wrong `inputs` list can hide a needed run. Only
  successes are cached, dirty inputs never are, and `check --no-cache` and the heavy run on the merge train
  limit the damage.
- A rule in its warn period lets a defect through for up to two weeks. That is the price of seeing its
  false alarms before it blocks anyone.
- Every delegation costs a few more lines of prompt. In return, rework is measurable, and briefs no
  longer say "fix it".
