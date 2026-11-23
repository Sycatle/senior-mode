---
id: 0022
title: The daemon merges in trains, builds on unmerged work, and shares one board across machines with git-ref leases
status: accepted
spec: 327
amends: 0017, 0018
---

## Context

ADR 0017 makes `serve` one loop per repository that starts Ready tickets in `pick` order, keeps its state in
`.git/senior-mode/serve/`, and recovers a lost ticket by putting it back to Ready. ADR 0018 lets a pull request merge on its
own when its three statuses are success on the head, one at a time. With the ruleset's up-to-date rule, each merge leaves the
next pull request behind, so k pull requests cost k check runs in sequence and none is checked with the ones that merge after
it. A ticket cannot start on work that is not merged, and one machine is the limit. Spec 327 turns the owner's decisions of
2026-11-23 into behaviour; this ADR records the choices that change 0017 and 0018.

## Decision

Amending 0018 (merges):

- Approved pull requests merge as a train of up to `autonomy.train` (default 3). The train is rebuilt speculatively on main,
  checked once on its tip, then merged in order, each by `gh pr merge --rebase --match-head-commit` after a server-side
  rebase. A status is carried to the rebased head only when its tree equals a tree that `check` passed (and `review` only when
  `git range-diff` shows the same patches). No gate is skipped, no bypass actor is added, no `--auto` is used for queue
  entries.
- A red tip is bisected over the ordered prefixes; the culprit leaves with the combination log and a fix round, the proven
  prefix merges, the rest forms the next train. If main itself is red, the queue stops under the environment hold of ADR 0021.
- A pull request that is stacked on another (base is not main) is never merged; after its parent merges the daemon rebases it
  with `git rebase --onto`, retargets it to main and requalifies it.

Amending 0017 (orchestration):

- Tickets are ordered by urgency, milestone, the critical path of the `blocked-by` graph, what they unblock, then Priority and
  number. Paths remain the collision rule, are proposed by the scout, verified against the diff, and widened by what a
  session actually touches.
- A ticket whose only open blocker has a green, open pull request starts on that blocker's branch (`autonomy.stackDepth`,
  default 2).
- The number of concurrent sessions is `min(autonomy.parallel, quota, memory, CPU)` with a reserve of the usage window kept for
  the owner (`autonomy.quotaReserve`, default 20 percent), and the daemon slows in bands before the limit.
- There can be one `serve` per machine, several machines on one repository. A worker claims a ticket, a pull request in review
  or the `leader` duties with a lease: a ref `refs/senior-mode/leases/<kind>-<n>` created and advanced only through the REST
  API's create-if-absent and fast-forward-only updates, holding a worker name and an expiry in GitHub server time. Expired
  leases are taken over; the single-process rule of 0017 now holds per machine.
- Each slot gets its environment from the committed `.senior-mode/slot.env` template (ports, database, compose project), with
  optional `slotDown` and `slotUp` commands.

## Alternatives considered

- **GitHub's merge queue:** its availability depends on the plan and the repository (the Free-plan sandbox is the case the
  project tests), and it expects the required checks to report on its `merge_group` event, which local CI (ADR 0006) never
  does: the checks run on the machine that owns them, and statuses are set by `publish`.
- **Merge one at a time, rebase and recheck each (today):** safe and simple, k checks per k pull requests, and it still does
  not test a combination before main moves.
- **Evict from the tail on a red train instead of bisecting:** linear in the train size, and blames the last pull request even
  when an earlier one is the culprit. Bisection is logarithmic and the prefix is already ordered.
- **Test each pull request alone on main, with no train:** the same cost as today and the combination failure stays possible
  between two green pull requests.
- **Lease as a Project field, a label, an assignee or a claim comment:** none can be created atomically or compare-and-swapped;
  two workers could both start a ticket, and a comment's visibility is eventually consistent, so even "lowest comment id wins"
  is unsafe. A claim comment with a settle delay is the fallback if refs turn out unusable.
- **An external lock service (Redis, a database):** a new thing to run and secure for a tool whose only dependencies are `git`,
  `gh` and the shell.
- **Lease times in local clocks:** skew would let a worker take a live lease or keep a dead one. Server time from the `Date`
  header of GitHub's answers, a margin, and refusal when the offset is large avoid it.
- **Stacked pull requests by merging the parent branch into the child:** a merge commit in a rebase-merge repository, and the
  parent's rewritten commits would conflict anyway. `--onto` replays only the child's commits.
- **Rely on GitHub retargeting a child when the parent's branch is deleted:** it does not help a rebase merge (the commits are
  rewritten) and the daemon must not depend on a side effect of branch deletion; it retargets itself first.
- **A fixed `parallel` only:** wastes capacity when the machine is idle and exhausts the owner's quota when it is not.
- **One shared environment with locks:** serialises exactly what the wave wants to parallelise.

## Consequences

- The speculative check on the tip is the one place where combinations are tested; the queue's correctness rests on the tree
  equality assertion after each merge and after each train.
- A third state domain appears (train, stacks, leases, the usage signal); each file follows the write and reconcile rules of ADR
  0021 and spec 373.
- The ref namespace `refs/senior-mode/leases/` is visible to anyone who can list refs and writable by anyone with push access
  to the repository; the lease is coordination, not a security boundary. Sandbox proof must confirm that custom refs work on a
  Free private repository under the ruleset.
- Stacking and the train need `--force-with-lease` pushes of daemon-owned ticket branches; no agent session gains that right
  (the guard still denies it to them).
- The weights, the quota bands and the 72-hour aging are first values, measured by the week-long run (#158) and changed by a
  later ADR or the configuration.
