---
id: 327
title: The daemon runs many tickets at once, on many machines, without breaking main
status: accepted
size: L
paths: ["plugins/senior-mode/bin/lib/serve.sh", "plugins/senior-mode/bin/lib/board.sh", "plugins/senior-mode/bin/lib/guard.sh", "plugins/senior-mode/bin/lib/check.sh", "plugins/senior-mode/bin/lib/setup.sh", "plugins/senior-mode/bin/lib/status.sh", "plugins/senior-mode/bin/lib/run.sh", "plugins/senior-mode/bin/lib/prompts.sh", "plugins/senior-mode/bin/lib/lease.sh", "plugins/senior-mode/agents/**", "plugins/senior-mode/presets/**", "plugins/senior-mode/templates/**", "docs/guide/**"]
adrs: ["0017", "0018", "0023"]
issue: "#327"
---

# The daemon runs many tickets at once, on many machines, without breaking main

## 1. Goal and non-goals

Spec 131 gave the daemon its loop: `serve` starts one session per Ready ticket in `pick` order, up to `autonomy.parallel`,
keeps tickets with overlapping Paths apart and merges one pull request at a time. It is correct and slow: the local
parallel-3 trial delivered about one ticket an hour (#355), started two tickets on the same files in one poll (#344), and
every merge costs a full check run because the ruleset requires an up-to-date branch. This spec makes the daemon fast
without making main less safe. Owner decisions of 2026-11-23 (issue #327) are fixed; this turns them into testable
behaviour.

Non-goals: changing who reviews or merges or any gate (ADR 0017, 0018, 0019): no status is skipped, no bypass actor is
added, every merge stays `gh pr merge --rebase --match-head-commit` on a head with the three statuses. No hosted service or
database. No multi-repository daemon (v1.4, #329).

Related work, reused and not redone:

- #355 (`ticketsPerHour` counts ticket starts; `sessionsPerHour` becomes a safety cap) and #344 (each launch of a poll sees
  the tickets started earlier in it) are v1.0 fixes that §2 and §6 assume. The CLI is split into `bin/lib/*.sh` (#315).
- The resilience epic #373 owns how state survives crashes: atomic state files, reconciliation at startup and each poll,
  the watchdog, the environment hold `held` (red main, disk, auth), `claude --resume` (#388), heartbeat (#390), self-health
  (#392), frozen plugin version (#395); see `docs/specs/373-resilient-autonomy.md`. This spec only adds state (`train`,
  `stack-<n>`, `usage`, leases) and its meaning; the files follow that spec's §3 (`state_write`, `state_update`) and are
  reconciled by its §2, and §4 and §8 use its environment hold and PR checkpoint resume.
- Spec 325 supplies the briefing and the scout's Paths. #308 (decision inbox, v1.3) later lists the drafts of §9.

New configuration, all optional with a safe default: `autonomy.train` 3, `autonomy.stackDepth` 2, `autonomy.quotaReserve`
20, `serve.leaseTtl` 600, `serve.worker` (hostname), `pipeline.minReady` 3, `pipeline.drafts` 3, `packages` (written by
`setup repo`). `autonomy.train: 1`, `autonomy.stackDepth: 0` and no `.senior-mode/slot.env` give today's behaviour.

## 2. Scheduling by the blocked-by graph

Tickets: #370. Needs #344.

The graph comes from what `board_data` reads: each open ticket's open `blockedBy`. A node is an open ticket, or an open
blocker not on the board (weight 3); an edge runs from blocker to blocked; a closed blocker is no edge. Weights: S 1, M 3,
L 8, no Size 3. For a ticket `t`:

- `cp(t)` = `w(t)` + the largest `cp` of the tickets `t` directly blocks (0 if none), over edges inside one milestone: the
  longest chain that cannot start before `t` ends, so the critical path of the milestone.
- `unblocks(t)` = open tickets that depend on `t`, directly or not, in any milestone.
- A cycle (a strongly connected component of 2 or more) is not schedulable: its tickets are skipped and get `needs-human`
  once, "blocked-by cycle: #a #b".

Among the tickets `pick` already selects (Ready, open, not L, no open blocker, no `blocked`/`needs-info`), the order is the
first difference in: (1) urgent first: P0, critical Severity, or Ready over 72 hours (aging, so nothing starves); (2)
milestone due date, none last; (3) `cp` descending; (4) `unblocks` descending; (5) Priority number; (6) Size S before M;
(7) ticket number. The order is total, so the same board prints the same order. For a startable ticket key 3 equals zero
slack: the critical path is the tickets with the milestone's largest `cp`.

Starting still goes through `pick_free`, with one added rule, head-of-line reservation: within a poll, a ticket may not start
if its Paths collide with an earlier ticket of the order that was passed over only because of a collision. A ticket passed
over for any other reason (no slot, a ceiling) reserves nothing. `pick --json` gains `cp`, `unblocks`, `critical`; `status`
prints the critical path of the nearest milestone ("#370 → #372 → #374, 7 points") and flags a size L blocker (it must be
split).

Acceptance criteria:

- Given Ready A (P2) that blocks two tickets and Ready B (P1) that blocks none, same milestone, then A starts first; if B is
  P0, B starts first.
- Given equal `cp`, `unblocks`, Priority and Size, then the lower number is first, and `pick` run twice prints the same order.
- Given a milestone due earlier, then its tickets precede a later milestone's whatever their `cp`.
- Given A blocks B blocks A, then neither is picked, both get `needs-human` once, and `serve` goes on.
- Given the critical ticket C waits on a running ticket with colliding Paths and a slot is free, then a ticket D whose Paths
  collide with C does not start and one that does not collide does.
- Given a ticket Ready for 73 hours, then it sorts with the urgent ones.

## 3. Paths: inferred, then verified

Tickets: #371.

Collision control is only as good as the declared Paths: too narrow and two sessions edit one file, too wide and nothing
runs in parallel. At framing the scout proposes Paths per ticket: where the change lands, plus importers of files it expects
to change, as the narrowest globs (a file, else a directory with `/**`, never a bare `**`). The spec's `paths` is the
ceiling: a proposal outside it is dropped with a note in the framing pull request.

`senior-mode ready --touched <pr>` (a new mode of `ready`) compares the Paths of the ticket the pull request closes with
`git diff --name-only --no-renames <base>...<head>`: `outside` are touched files matching no declared glob (lockfiles never
count), `unused` are declared globs matching no touched file. When `outside` is not empty it widens the field to the declared
globs plus the outside files and comments on the ticket with `<!-- paths-gap: outside=N unused=M -->` and the list. The
marker is the record, read from GitHub by `retro`, which reports Paths accuracy (share of tickets without a gap, most missed
globs). `serve` runs it once per head when it first sees the pull request In review.

Live widening: each poll, for every running session, `serve` reads the worktree's `git diff --name-only` (committed and
not). A file outside the Paths widens the field at once, so the same poll's later launches collide with the real footprint.
It never stops a session; if the widened Paths now collide with another running ticket it only logs both numbers, and the
queue (§4) settles the overlap at merge.

Acceptance criteria:

- Given Paths `src/a/**` and a pull request touching `src/a/x.ts` and `src/b/y.ts`, when `ready --touched` runs, then the
  field is `src/a/**,src/b/y.ts`, the ticket has one comment `paths-gap: outside=1 unused=0`, and a second run changes
  nothing.
- Given a pull request touching only `package-lock.json` beyond its Paths, then there is no gap.
- Given a running session that creates `src/c/z.ts`, then the field includes it before the next launch of that poll.
- Given a ticket with no Paths, then the field is filled from the diff and the comment says it had none.
- Given a scout proposal outside the spec's `paths`, then it is not written; `retro` prints the accuracy over gaps.

## 4. The local merge queue

Tickets: #372, #421; reuses #412. Amends ADR 0018.

Today the integrator merges one approved pull request per poll. With the up-to-date rule each merge leaves the next one
behind: it is rebased on the server and `serve_requalify` runs `check` again, so k pull requests cost k check runs in
sequence, and none of them has been checked with the ones that merge after it.

A pull request is queueable when it passes today's `run_blocker` (the three statuses on its head, no `needs-human`, not
draft, no protected zone) and its base is main (§5). The queue runs when `autonomy.merge` is true and `autonomy.train` > 1.

Formation. With no train in flight, a poll takes up to `autonomy.train` queueable pull requests in §2 order (a stacked one
never precedes its parent) and, in a detached worktree at `origin/main`, builds a speculative stack with `git rebase
--onto`: entry 1 on main, entry 2 on entry 1, and so on. An entry that conflicts leaves the train for `serve_conflict` and
the rest goes on. State is `.git/senior-mode/serve/train` (id, base sha, entries with pull request, head, speculative sha
and tree, phase `building|checking|merging`).

Check. `check` runs once on the tip, under a slot (§7) that counts against `autonomy.parallel`, on the union diff in a
monorepo (§10). Results are cached by tree, so a rebuilt train with an identical tip does not run again.

Merge. While `origin/main` equals the train's base, entries merge in order; for each: `gh pr update-branch --rebase` (the
up-to-date rule), the new head's tree must equal the entry's speculative tree, `senior-mode/ci` is carried over (#412),
`security` recomputed by `publish` (cheap), `review` carried over when `git range-diff` shows the same patches as today,
then `gh pr merge --rebase --match-head-commit <head>`, and Done once `state == MERGED` is read back. A different tree or a
review that cannot be carried drops that entry and the rest, to be rebuilt; if main moved, the train is rebuilt. Queue
entries are never queued with `--auto`: the order is the daemon's. After the last merge `origin/main`'s tree must equal the
tested tip; otherwise `check` runs on main at once, and a red main sets #373's environment hold (`held`) and an alert (nothing is
reverted automatically).

Failure isolation (#421). A red tip is bisected over prefixes of the ordered train: it checks the prefix of ⌈k/2⌉ entries
and narrows to the first red prefix, ⌈log₂ k⌉ runs. Entries before the culprit are proven green together and merge now;
those after it form the next train. The culprit gets a comment with the combination log and its ticket session resumes with
the findings as in a review round (`serve_changes`: 2 rounds, then `needs-human`). If the empty prefix is red the culprit is
main: the queue stops with "main is red". A red tip whose prefixes are all green is rebuilt once as a flaky check and, if it
recurs, goes to `needs-human`. Eviction from the tail was rejected (ADR): up to k runs, and it blames the wrong pull
request when the culprit is not last.

Branch protection and the integrator. Nothing is bypassed: the ruleset, the three statuses and the up-to-date rule apply to
every merge, with no bypass actor; statuses carried to a new head are set only when its tree equals a tree `check` passed.
Without a ruleset (`github.protection` none) the queue is the same. `serve_rebase` is the update step, `serve_requalify` the
carry-over, `serve_conflict` the path of a conflicting entry, `serve_do_merge` the merge; with `autonomy.train: 1`
`serve_merge` works as today.

Acceptance criteria:

- Given three queueable pull requests whose combination is green, then `check` runs once, the three merge in order with no
  further `check`, and each is Done.
- Given A renames a function and B (green alone) calls the old name, then the tip is red, bisection names B, A merges, B
  gets the log and a fix round, and main's `check` never fails.
- Given main moved before merging starts, then nothing merges and the train is rebuilt; a rebuilt tip with an already
  checked tree runs no `check`.
- Given an entry whose rebased head has another tree than planned, then it and the entries after it rejoin the next train.
- Given a conflicting entry, then it leaves the train, `serve_conflict` starts, and the others merge.
- Given main's `senior-mode/ci` is failure, then no train forms, one alert is raised and `held` is set.
- Given `autonomy.train: 1`, then behaviour is that of spec 131. After every train main's tree equals the tested tip.

## 5. Stacked pull requests

Tickets: #374, #416; reuses #412. Amends ADR 0017 and 0018.

A ticket with an open blocker is not picked today. Ticket T may instead start on its blocker B's branch when: B is T's only
open blocker; B has an open, non-draft pull request with `senior-mode/ci` success and no `needs-human` (B's session is over);
and the stack depth is under `autonomy.stackDepth` (default 2, 0 turns it off).

Base rules. `start <T> --base <B's branch>` branches from `origin/<B's branch>` and T's pull request is opened with that
branch as base, so its diff is T's alone. `.git/senior-mode/serve/stack-<T>` records the parent pull request, its branch and
the parent head T was last rebased on. The parent's remote branch is never deleted while an open pull request targets it
(`clean` already skips it). T's Paths may overlap B's: B is not running, so `pick_free` ignores it. A pull request whose
base is not main is never queueable; its reviewer sees the diff against the parent.

After the parent merges, in the train's merge step before anything else touches T: `git rebase --onto origin/main <recorded
parent head> <T's branch>` (replays only T's commits, since a rebase merge rewrote B's), push the daemon-owned branch with
`--force-with-lease` against the recorded head, `gh pr edit <T> --base main`, then requalify as in §4. T is queueable at the
next poll, or joins the same train behind B when it was queueable at formation. When the parent's branch moves (a fix round)
the same `--onto` rebase runs against the new head at the next poll; when it is replaced by an integrator branch
(`Supersedes #old`), T's base moves to it.

Failure path: a rebase conflict makes T an ordinary conflicting pull request, and `serve_conflict` starts the integrator on a
`-r2` branch. A parent closed unmerged gives T `needs-human` ("its dependency #B was closed without merging"), branch kept.
If GitHub closed T because its base was deleted, the daemon opens a new pull request from the branch with "Supersedes #old";
it does not rely on GitHub's retargeting and retargets first.

Acceptance criteria:

- Given B In review with `ci` success and T blocked only by B, when `serve` polls with a free slot, then T starts on a branch
  from B's and its pull request has B's branch as base.
- Given T blocked by B and C, or by a B without pull request, or `autonomy.stackDepth: 0`, then T does not start.
- Given B merges through the train, then T is rebased with `--onto`, its base is `main` and GitHub's diff is T's commits only.
- Given T conflicts with main after B merged, then the integrator starts on `T-r2`.
- Given B closed unmerged, then T has `needs-human` and its branch exists. Given T's base is not `main`, the queue never
  merges it. Given B's branch moves, T is rebased on it at the next poll.

## 6. Parallelism that follows quota, memory and CPU

Tickets: #376, #410. Needs #355.

The target number of sessions becomes `min(autonomy.parallel, quota, memory, CPU)`, recomputed each poll; a session starts
only while fewer run than the target.

Signals:

- Usage window: `{window: five_hour|seven_day, used_percent, resets_at, observed_at}`. The source is what spike #410 finds on
  the installed Claude Code (a rate-limit event in `stream-json`, the statusline input, the result JSON); the runner changes
  its output format only if the spike says the event is there. The signal is account-wide, so all machines of §8 read the
  same window. With no usable source the controller keeps today's reactive hold (`serve_limit`) and estimates from the
  tokens its sessions used against the total at past limit hits; the estimate only slows. A signal older than 15 minutes
  while sessions run is unknown: logged once, ignored.
- Memory: (`MemAvailable` − `autonomy.minMemoryMB`) / session footprint, the moving average (weight 0.3) of the peak resident
  size of finished sessions' process groups, first 1500 MB. With `/proc/pressure/memory`, `some avg10` over 10 stops launches.
- CPU: `nproc` − one-minute load − 0.5, rounded down. With `/proc/pressure/cpu`, `some avg10` over 40 stops launches. Linux
  only; elsewhere today's load and memory fallbacks stay.

Bands. `B = 100 − autonomy.quotaReserve` (default 80) is the share of the window the daemon may use; the rest is the owner's
interactive reserve. With `u` the larger `used_percent` of the two windows: `u < 0.6 B`: full target. `0.6 B ≤ u < 0.85 B`:
half, at least 1, and no pipeline drafts (§9). `0.85 B ≤ u < B`: no new ticket, but reviewers, the integrator and finishing
sessions go on. `u ≥ B`: nothing launches until reset (held like `limit-until`, reason "reserve"). Pace: when the
seven-day `u` is over the elapsed share of the week by 15 points, the target is halved, so a run does not spend the week in
two days. Interactive: while a `claude` process of the same user that `serve` did not start (no `SENIOR_MODE_RUN=1` in its
environment) runs, `B` is lowered by 10 and the memory and CPU margins by one session. These constants are first guesses
that #158 measures.

`ticketsPerHour` and `sessionsPerHour` (#355) stay hard caps. A waiting launch names its binding limit in the log ("quota
5h 72% of 80%: target 2", "memory: 1 session fits"); `status` and the digest show the band and mean parallelism.

Acceptance criteria:

- Given `parallel 4`, `u` 30%, memory for 6 more sessions and CPU for 5, then the target is 4; with room for 1 more while 3
  run, one starts and the log names memory only if it binds.
- Given `quotaReserve 20`: at `u` 50% the target is 2; at 70% no ticket starts but a reviewer does; at 80% nothing starts and
  the hold names the reserve and the reset time.
- Given the seven-day window at 60% with 20% of the week elapsed, then the target is halved. Given an interactive `claude`
  process, then `B` is 70.
- Given no usable signal, then the reactive hold applies, "no usage signal" is logged once an hour, and the daemon never
  exceeds `autonomy.parallel`. Given a 20-minute-old signal with sessions running, then it is ignored and logged once.
- Testable with `SENIOR_MODE_USAGE` (a JSON file), `SENIOR_MODE_MEMAVAILABLE`, `SENIOR_MODE_LOADAVG`,
  `SENIOR_MODE_PRESSURE_DIR`.

## 7. An isolated environment per slot

Tickets: #378.

Slots exist (`slot_acquire`: an `flock` per number, freed by a crash) and a `slot` config command can print `KEY=VALUE`.
Missing: a contract that needs no shell, and the other shared things (a second port, a database, a compose project, a cache).
`.senior-mode/slot.env` is a committed template of `KEY=VALUE` lines (`#` and blank lines skipped):

```
PORT={{port:3000}}
DATABASE_URL=postgres://localhost:5432/{{repo}}_s{{slot}}
COMPOSE_PROJECT_NAME={{repo}}-s{{slot}}
CACHE_DIR={{slotdir}}/cache
```

Tokens: `{{slot}}` (N), `{{port:BASE}}` (BASE + N), `{{repo}}`, `{{ticket}}`, `{{worktree}}`, `{{machine}}` (the worker name of
§8, for a database server shared by machines), `{{slotdir}}` (`~/.local/share/senior-mode/slots/<repo>-<hash>/N`, kept
between tickets). An unknown token, a `SENIOR_MODE_` key, a non-identifier name, a newline in a value or a port outside
1..65535 stops the session before it starts, as a failing `slot` command does today. The file holds no secret. The `slot`
command still works: the template is read first and the command's lines override.

Ports: `slot_acquire` bind-tests the slot's ports and skips a slot whose port a foreign process holds; when none is free the
session waits and names the port. Lifecycle: optional config commands `slotDown` (idempotent) and `slotUp`, run with the
slot's environment in the worktree: down then up before a session, down after it, whatever the exit. A crash leaves at worst
a stale environment that the next claim cleans first; #373's startup reconciliation runs `slotDown` on free slots.
`setup repo` writes a stub from what it detects (a `PORT` for a node server; `COMPOSE_PROJECT_NAME` and a `docker compose
down -v` suggestion when a compose file exists; a `DATABASE_URL` only if the project declares one) and never overwrites. The
train's `check` (§4) and any session running the `e2e` check take a slot; `e2e.slots` is unchanged.

Acceptance criteria:

- Given the template above and slots 1 and 2 running, then they get ports 3001 and 3002, databases `repo_s1` and `repo_s2` and
  distinct compose projects.
- Given `{{unknown}}`, a `SENIOR_MODE_X` key, or `PORT={{port:65535}}` on slot 2, then the session does not start and the
  message names the line.
- Given port 3001 held by a foreign process, then the session takes slot 2 and logs why; with every port busy it waits and
  names the port.
- Given `slotDown` and `slotUp`, the order is down, up, session, down, also when the session is killed.
- Given no template and no command, behaviour is today's. Given a compose file, `setup repo` writes a per-slot project name
  and a second run changes nothing.

## 8. Several machines, one board

Tickets: #380, #414, #416. Amends ADR 0017. Uses #373.

Each machine runs its own `serve` (one per clone) with a worker name (`serve.worker`, default the hostname). They share the
board and the repository on GitHub and nothing else.

Where the lease lives. No field, label or comment can be created atomically or compare-and-swapped, and two workers must not
start one ticket. The authority is a ref created through the REST API (`POST git/refs` fails if the ref exists; `PATCH
git/refs` with `force: false` fails unless it is a fast-forward): `refs/senior-mode/leases/ticket-<n>`, `review-<pr>` (a
reviewer or merge in progress) and `leader` (the singleton duties). A lease is a commit with the empty tree whose message is
JSON: `worker`, `expires` (server epoch), `renewed`, `reason` (`claim|renew|takeover|release`). Claim creates the ref; renew
and takeover add a child commit by fast-forward, so racing workers get one winner, and the ref's history is the audit trail
(takeovers, who, when). For people, a label `worker:<name>` is set at claim and removed at release; it is never read as
authority and `status` repairs it and lists the leases.

Claiming. Before `run_start` a worker claims `ticket-<n>`; a lost claim means skip; Status becomes In progress only after the
claim. The set of tickets that "run" for `pick_free` is the tickets with a valid lease on any machine, so Paths collisions
hold across machines. Reviewer and integrator sessions claim `review-<pr>`. The duties two daemons would duplicate (digest,
filing security alerts, Ready by rule, the train) run only on the holder of `leader`.

Expiry. `serve.leaseTtl` is 600 s; a worker renews each lease it holds when under half the TTL remains. Times are GitHub
server time: each API answer's `Date` header gives an offset, the worker keeps the median of the last five, and
`server_now = local_now + offset`. A lease is expired when `server_now > expires + 30` s. A worker whose offset is older than
5 minutes or larger than a quarter of the TTL claims nothing and says "clock": a wrong clock can neither take a live lease nor
keep a dead one.

A dead worker. A worker that finds an expired lease on an In progress ticket takes it over (one succeeds) and starts it as an
interrupted session: `start` from the remote branch (#416) and #373's PR checkpoint, since `claude --resume` is local to the
dead machine. Takeovers count toward `autonomy.maxConsecutiveFailures`, then `needs-human`. A lease on a Done, closed or
`needs-human` ticket is released by whoever sees it. Fencing: a worker that cannot reach the API keeps its sessions until the
lease is nearly expired, then stops launching; one that finds its lease taken kills that session; before an effect others see
(merge, status, push by the daemon) it rereads its lease and skips the effect if it is not the holder.

`autonomy.parallel` is per machine; the usage window is account-wide (§6), so all workers see the same bands.

Acceptance criteria:

- Given two workers and one Ready ticket polling at once, then exactly one starts it and the other logs it is leased.
- Given a worker killed with `kill -9` holding a lease, then `leaseTtl` + 30 s later another worker takes the ticket over,
  resumes from the remote branch, and the ticket ends merged once with one takeover in the ref's history.
- Given a worker whose clock is 120 s fast, then it refuses to claim and says why, and no live lease is taken from another.
- Given a live worker whose renewal is refused after a network cut, then it kills the session and neither pushes nor merges.
- Given overlapping Paths on two machines, then the tickets never run together. Given two workers, the digest is posted once
  a day and one train runs at a time.
- Given `leaseTtl` under three poll intervals, then `serve` refuses to start. If the sandbox rejects refs under
  `refs/senior-mode/`, #414 reports it (open questions).

## 9. An always-fed pipeline

Tickets: #383. Needs #370.

The daemon idles when no Ready ticket is runnable. Below `pipeline.minReady` runnable tickets (Ready, open, not L, no open
blocker, not running, not `needs-info`), with the §6 band under 0.6 B and fewer than `pipeline.drafts` drafts open, `serve`
starts `architect` sessions to pre-frame Backlog ideas, one per idea, up to `pipeline.drafts` minus the open drafts, on spare
capacity and never ahead of a ticket that could run. An idea is an open Backlog issue with no `needs-human`, no open draft
and a parent epic in an open milestone, taken in §2 order.

A session runs the existing framing flow unattended (`frame start`, role `frame`, the frame guard): a spec section or ADR
only when the size calls for it, criteria (Given/When/Then), Size, Priority, `blocked-by`, the scout's Paths (§3), an L split
into S and M tickets, then a draft pull request on `docs/<n>-<slug>` labelled `framing-draft` listing the tickets. The ideas
stay in Backlog. A draft is never self-approved: the owner approves by merging it (one tap on the phone) and `ready --pr`
sets Ready the tickets that pass the Definition of Ready, as in spec 131; the inbox (#308) will list drafts. A draft the
owner closes returns the idea with a comment, not offered again for 14 days. With the Backlog empty the daily digest says the
pipeline starves, once a day, and the owner is notified.

Acceptance criteria:

- Given 1 runnable ticket, `minReady` 3, band under 0.6 B, room for drafts and 5 Backlog ideas, then one framing session
  starts on the first idea of the order and ends with a `framing-draft` pull request; no ticket becomes Ready.
- Given 3 open drafts, or a higher band, or 3 runnable tickets, then no framing session starts.
- Given the owner merges a draft, then its qualifying tickets are Ready at the next poll; one that fails the Definition of
  Ready has `needs-human` saying what is missing.
- Given a closed draft, then its idea is not framed for 14 days. Given an empty Backlog, then one starving line and one
  notification a day. A framing session never merges, sets Ready or touches a protected zone.

## 10. Monorepos

Tickets: #323, #418.

Detection. `setup repo` finds npm/pnpm/yarn workspaces (`package.json` `workspaces`, `pnpm-workspace.yaml`), Cargo
workspaces and Go repositories with several `go.mod` or a `go.work`, and records in `.claude/senior-mode.json`:

```json
"packages": { "packages/api": { "preset": "node", "commands": { "lint": "...", "test": "..." }, "deps": ["packages/shared"] } }
```

Commands run in the package directory. `deps` comes from the manifests (workspace dependencies, `cargo metadata` path
dependencies, `go.work` and `replace`). Root `commands` stay for repository-wide work; `install` runs once at the root, except
Go, once per module.

Selection (#418). The affected set is every package containing a file of `git diff --name-only <base>...HEAD`, plus its
dependents, transitively. The graph is the union of the base's and head's manifests, so a pull request cannot hide a
dependency it adds. A changed file outside every package (a root config, a lockfile, `.github/**`, `.githooks/**`) selects
all. Repository-wide checks (commit subjects, secrets, docs, sizes) always run; `check --all` runs everything.
`senior-mode/ci` stays one status, success only if every selected package passes, described as `3 of 12 packages: api,
shared, web`. Paths do not select (they are declared; the diff is true); before a diff exists they only narrow `start`'s
install and the briefing. The train's tip (§4) selects on the union diff. No `packages` key: behaviour as today.

Acceptance criteria:

- Given fixtures (a pnpm workspace, a Cargo workspace, a Go repository with two modules), `setup repo` records `packages` with
  commands and `deps`; a second run changes nothing.
- Given a diff in `packages/shared` that `packages/api` depends on, then `check` runs both and not `packages/web`; given a
  diff only in `web`, it runs `web` and the repository-wide checks.
- Given a diff touching `pnpm-lock.yaml`, or `check --all`, then everything runs.
- Given a pull request that adds `web → shared` in its manifest and changes `shared`, then `web` runs.

## 11. The proof: a week of the daemon (#158)

Tickets: #158, #423. Each of §2 to §8 is first exercised on `Sycatle/senior-mode-sandbox` with its faults injected on purpose
(ADR 0011); the week is the wave's end-to-end proof.

Setup. The v1.2 release candidate is installed and its version stays fixed for the week (#395, else by not updating). The
`serve` unit runs on one dedicated Linux machine with `autonomy.parallel` 3, train, stacking, quota bands and `slot.env`
enabled, on this repository; a second machine joins on day 3 as a second worker. At least 15 S and M tickets of the next wave
are Ready at the start and §9 feeds the queue after. The owner only answers `needs-human`, approves drafts and logs every
other intervention on #158. `serve` writes an hourly snapshot (#423) and `retro --since 7d` prints the run proof.

Pass criteria (from #158; failing one stops the proof): (1) no merge bypassed a gate: for each pull request merged in the
window, `ci`, `review`, `security` were success on the merged head, `review` was set by a reviewer session, no bypass actor or
admin merge appears; (2) no secret leaked: no new secret scanning alert and a clean `secret-scan` over the window's commits;
(3) no drift: the board's drift count is zero in the last snapshot of each day and at the end; (4) every incident is an
issue: each `needs-human`, breaker pause, takeover, evicted entry, environment pause and restart has an issue; (5) main
stays green: `senior-mode/ci` is success on every commit of main in the window; (6) no duplicate work: no ticket had two
sessions at once, from the lease histories.

Measured, compared with the parallel-3 baseline of about one ticket an hour: tickets merged per day, mean sessions running,
starvation minutes (a free slot, no runnable ticket), tickets per train, evictions, bands entered and reactive limit hits
(target zero when a signal exists), takeovers, hands-off ratio. They go in a comment on #158.

Faults, so the week shows recovery as well as the happy path: day 2 `kill -9` of `serve` during a train's merge step; day 4
`kill -9` of the second worker holding a lease (takeover within `leaseTtl` + two polls); a reboot; a pair of tickets that
conflict only in combination, on the sandbox. A gate bypass or a leaked secret fails the proof: stop, fix the cause, restart
at day 0. Any other incident is filed and fixed without restarting the clock unless `serve` was down over an hour.

Acceptance criteria:

- Given the setup, after seven days the pass criteria hold and the `retro` section is copied to #158.
- Each of §2 to §8 has a recorded sandbox session in the pull request that merged it. Epic #327 closes when its sub-issues
  and #158 are closed.

## Out of scope, test seams, open questions

Out of scope: several repositories (#329), a dashboard, an agent identity (#175), a cap on sessions across machines, and
lockfile regeneration in a train rebase (a lockfile conflict goes to the integrator).

Test seams: `pick`, `queue_lines`, `serve_poll`, `serve_can_launch`, the train and stack steps, `slot_acquire`, `slot_env`,
the lease module, `check` and `setup repo` in `bin/lib/*.sh`, through `bin/tests/test-*.sh` with the `gh`, `claude` and `git`
stubs, `SENIOR_MODE_SERVE_ONCE=1`, `SENIOR_MODE_NOW`, the §6 inputs, and a `gh` stub with create-if-absent and
fast-forward-only refs for §8. Real sessions, GitHub's ref semantics and the ruleset are exercised on the sandbox (ADR 0011).

Open questions:

- Lease storage (§8): recommended is a ref with a mirror label; #414 must confirm on the sandbox that custom refs are accepted
  on a Free private repository under the `senior-mode` ruleset and that the `pre-push` hook does not touch them. Otherwise
  the fallback is claim comments arbitrated by lowest comment id plus a settle delay, which is weaker.
- `ready --touched` (§3) avoids a new verb during the surface audit (#318); `publish` could host it instead.
- Weights (§2), the reserve and band constants (§6) are first guesses; #158 measures them. No usage signal is assumed until
  #410 reports.
- Flaky checks (§4): one rebuild, then `needs-human`; a per-check retry policy waits for evidence from the proof.
- Proof machine (§11): `sya-dev-01` has expired but #158's title and body still name it. Recommended: the owner provides one
  Linux host with systemd and `flock`, and #158 is retitled.
- Drafts (§9) before the inbox exists: approval is merging the framing pull request.
