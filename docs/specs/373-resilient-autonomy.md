---
id: 373
title: The daemon survives crashes, outages and bad environments without a human, and proves it
status: accepted
size: L
paths: ["plugins/senior-mode/bin/senior-mode", "plugins/senior-mode/bin/lib/**", "plugins/senior-mode/bin/tests/**", "plugins/senior-mode/templates/**", "docs/guide/autonomy.md", "docs/guide/configuration.md"]
adrs: ["0017", "0021"]
issue: "#373"
---

# The daemon survives crashes, outages and bad environments without a human, and proves it

## Problem

`serve` (spec 131, ADR 0017) must run for weeks unattended. The local trial of 2026-11-23 showed it
does not yet: a session that died on "still loading your organization's settings" was counted as a
model failure and escalated to Opus (#334); a restart puts a ticket whose session had already written
`delivered` back to Ready, because `serve_recover` never reads its outcome; the breaker conflates "the
ticket is bad" with "the world is down" and pauses a flat hour; state files are written in place; no
test kills the daemon anywhere but between polls. The owner's framing of 2026-11-23 (epic #373) is
applied as written; ADR 0021 records it and amends ADR 0017.

## Users and journeys

- **The owner**, away a week through an outage, an API incident, a full disk and a reboot, comes
  back to a board with nothing half-done and one alert per cause, not per ticket.
- **The daemon**, killed at any instant (`kill -9`, power cut), finds on restart every ticket in one
  defined state, without help.
- **The release manager** runs the chaos suite on the sandbox before tagging.

Conventions: `serve dir` is `<git common dir>/senior-mode/serve/`; `<n>` a ticket; a *session* one
`claude -p` process group from `run_launch`; criteria are tagged **[v1.0]** or **[v1.2]**. Signals
are matched case-insensitively on the first 20 KB of `<n>-<model>.json` and `.log`, as `serve_limit`
does, from one function (`serve_patterns`): a new message is a one-line change with a fixture.

## 1. Failure taxonomy

`serve_classify <n>` classifies every session end once, before anything else reads it. First match
wins:

1. **Verdict.** `<n>.outcome` with a first line `delivered`, `outgrown: ...` or `failed: ...` (batch:
   `#n ...` lines) is the session's own verdict: *ticket* class, handled by `run_finish` as today. A
   partial or unparseable file counts as absent.
2. **Usage limit**, then 3. **Environment**, then 4. **Transient** (table), then 5. **Ticket**:
   anything else, such as an end without verdict, a `delivered` with no open pull request, a
   reviewer that left no `senior-mode/review`.

| Class | Signals | Reaction | Breaker and `ticketsPerHour` |
|---|---|---|---|
| Transient: network, API | `ECONNRESET`, `ECONNREFUSED`, `ETIMEDOUT`, `EAI_AGAIN`, `ENOTFOUND`, `socket hang up`, `fetch failed`, `Unable to connect`; `API Error: (429\|5xx)`, `overloaded_error`, `api_error`, `Overloaded`, `Service Unavailable`, `Bad Gateway` (`Retry-After` honoured); `gh` `HTTP 5xx`, `timed out` | Same model, same worktree, relaunch after backoff | Not counted |
| Transient: startup | exit 1, no outcome, ran under `autonomy.startupSeconds` (30), and `still loading your organization's settings` or empty output (#334) | As above; 3 in a row pause launches | Not counted |
| Transient: usage limit | `limit reached\|hit your( [a-z-]+)? limit\|usage limit` | Nothing launches until the reset read by `serve_reset` plus 60 s; ticket back to Ready, worktree kept | Not counted |
| Transient: interrupted | Killed by serve's own stop (`serve.grace` over) or by the watchdog's first kill (section 4) | Ready again (watchdog: relaunched at once), no `needs-human` | Not counted |
| Environment: disk | `ENOSPC`, `No space left on device`, `Disk quota exceeded`; probe: free MB under `autonomy.minDiskMB` (2048) on the worktree and temp file systems | Clean (`senior-mode clean`, logs over 7 days, `git worktree prune`), re-probe, else hold | Not counted |
| Environment: auth | gh: `HTTP 401`, `Bad credentials`, probe `gh api user`; claude: `authentication_error`, `Invalid API key`, `OAuth token ... expired`, `Please run /login`, `credit balance is too low`, probe `<agent.command> auth status` else a one-token ping | Hold | Not counted |
| Environment: red main | probe: `senior-mode/ci` of the base head is not success | Hold ticket launches; green pull requests still merge (a fix has to land) | Not counted |
| Environment: dependencies | probe: `install_command` fails in a scratch worktree of the base head | Hold ticket launches | Not counted |
| Environment: memory | `Cannot allocate memory`, `ENOMEM`, exit 137 with `MemAvailable` under `autonomy.minMemoryMB` | Wait (today's ceiling), not a hold | Not counted |
| Ticket | step 5; a watchdog second kill; a lost session recovered `maxConsecutiveFailures` times | Opus once (ADR 0014), then `needs-human`, as today | Counted |

**Diagnose before blame.** A ticket-class end with no verdict runs the cheap probes (disk, gh auth,
main status) before it is recorded; a red probe reclassifies it as environment (ticket back to
Ready, nothing counted). A session's own `failed:` verdict is never reclassified, but the probes
still run once afterwards, so a hold starts before the next launch.

**Transient backoff.** `delay(k) = min(serve.backoffMax, serve.backoffBase * 2^(k-1))`, base 30 s,
max 900 s, plus 0 to 20 % jitter: 30, 60, 120, 240, 480, 900 s. `k` counts consecutive transient
ends of the ticket (`<n>.transient`) and resets when a session produces a verdict or a pull request.
A usage limit with no reset time waits 5, 10, 20, 40, 60 min, not a flat hour. The third transient
startup in a row, across tickets, sets `launch-backoff-until` and logs `serve: 3 sessions in a row
died at startup; not launching until <time>`; it never escalates the model. After 10 consecutive
transient ends of a ticket one `environment` alert ("API unreachable for about an hour") is sent and
retries go on at the cap: a transient never becomes `needs-human`. A transient end removes its line
from `launches`, so it counts for neither `ticketsPerHour` (#355) nor `sessionsPerHour`.

**Environment hold.** `held` is one JSON object `{cause, since, probe, nextProbe, detail}`; the log
line and the alert carry the exact cause (`serve: holding all launches: disk full, 312 MB free of
autonomy.minDiskMB 2048 on /home/..., probing every 60 s`). Running sessions finish; their ends are
classified again. Reviews and merges need no launch and continue, except under gh or claude auth
holds. Cheap probes run every poll, expensive ones (claude ping, dependencies) every 5 min, then
every 15 min after an hour. A green probe removes `held`, sends one `recovered` alert and Ready
tickets start in `pick` order. `serve --resume` lifts `held` and the breaker's `paused` and forces a
probe. Alerts use the webhook of spec 131 (`{event, repo, number, url, reason}`) with the new events
`environment` and `recovered`, `number` empty.

**Circuit breaker.** It counts **ticket**-class failures only (`RUN_FAILS`, `maxConsecutiveFailures`,
default 2); a delivered ticket resets it, a hold neither counts nor resets. A trip pauses launches
for `min(serve.breakerMax, serve.breakerCooldown * 2^(trips-1))`: with `breakerCooldown` **900 s**
(was 3600) and `breakerMax` 14400 s, 15, 30, 60, 120, 240 min. `trips` (file `breaker`) resets
after a merged ticket or 24 h without a trip; `serve --resume` sets it to 0. It never exits and
alerts once per trip.

### Acceptance criteria

- Given a session whose only output is `Claude Code is still loading your organization's
  settings` (exit 1), when it ends, then it relaunches on the same model after about 30 s,
  `RUN_FAILS` and `launches` are unchanged and nothing escalates; after 3 in a row nothing launches
  until `launch-backoff-until`, and the log says why. [v1.0]
- Given a stub `claude` that prints `API Error: 529 overloaded_error` on its first 4 launches, then
  works, then launches are spaced about 30, 60, 120 s on the injected clock, the ticket is
  delivered and `RUN_FAILS` is 0; given a session ending on `resets 3pm (Europe/Paris)`, no role
  launches before 15:01 Paris time and the ticket is Ready. [v1.0]
- Given a session dead of `ENOSPC` with `df` at 100 MB, then logs over 7 days are removed; still
  red, `held` names the disk and mount, one alert goes out, the ticket is Ready and `RUN_FAILS` is
  unchanged; with `df` at 10 GB the next poll lifts the hold with no human. [v1.0]
- Given a red `senior-mode/ci` on the base head, then no ticket session starts and an approved green
  pull request still merges; given `gh` answering 401 then 200, `held` names gh auth, nothing is
  labelled `needs-human`, and with main green or the token valid launches resume by themselves. [v1.0]
- Given 2 ticket failures in a row the breaker pauses 15 min, a second trip 30 min, a merged
  ticket resets `trips`; given 5 transient ends the breaker never trips. [v1.0]

## 2. Reconciliation model

At start and at the beginning of each poll, before it launches anything, the daemon rebuilds its
picture from GitHub and the disk, then repairs. GitHub (board, branches, pull requests, commit
statuses) is the source of truth; the serve dir is a cache and a journal of intent. Losing the whole
serve dir loses logs and counters, never a ticket. Pass order: (a) sessions: read ends, adopt those
of a dead daemon, sweep orphans; (b) worktrees and locks; (c) tickets In progress; (d) pull
requests; (e) Ready and launches.

| Step | Source of truth | Idempotent because | Repair after `kill -9` between its writes |
|---|---|---|---|
| Open ticket | `git worktree list`, branch, board Status | `start` reuses an existing worktree; Status is set to a value | Worktree without In progress: set it; In progress without worktree: recreate from remote branch or base |
| Launch | `<n>.meta`, process group, board | `<n>.meta` written *before* launch; a live group is never launched over | Meta, no group, no `.exit`: lost session (below) |
| Read end | `<n>.exit`, `.outcome`, `<n>.json` | `<n>.json` newer than `<n>.meta` means read; classification is a pure function of the files | Ended, no `.json`: classify now (today the verdict is lost) |
| Push | `git ls-remote origin <branch>` | pushing an unchanged ref is a no-op, never forced | Commits ahead of remote with `delivered`: push |
| Open pull request | `pulls?head=<owner>:<branch>&state=all` | created only when none exists for the head | Pushed, `delivered`, no pull request: serve opens it (`Closes #n` each) |
| Statuses | `commits/<sha>/status` | keyed by (sha, context); publish skips a context already success | Head without status: published or reviewed next poll |
| Review | `senior-mode/review` on the head, live reviewer | starts only when absent and none alive for that head | Reviewer ended transient: relaunched |
| Queue auto-merge, review rounds | `pr.state`, `autoMergeRequest`; comments with `<!-- senior-mode:round -->` | `--auto --match-head-commit <sha>` repeated is a no-op or refused; `queued-<pr>` and `rounds-<t>` are caches | Cache lost: recomputed, candidate again |
| Merge | `pr.state == MERGED` read back | `--match-head-commit` forbids a second merge; the exit code is never trusted | Merged, ticket not Done, no `queued-` file: Done (checked every poll) |
| Board Done | Board Status | set to a value; `cycle_end` once per ticket | Done without `cycle_end`: recorded next poll |
| Clean | pull request merged or closed, ticket Done | `clean` removes what exists | Orphan worktree: removed; dangling registration: `git worktree prune` |
| `needs-human` | label, comment marker `<!-- senior-mode:needs-human:<hash> -->` | comment first (skipped if the marker exists), then label | Either half missing: the other added |
| Ready by rule, digest | merged `docs/` pull requests since `ready-last`; `digest` time | only Backlog tickets that pass move; mark written after success; digest at most daily | Re-read with no effect; one digest may be lost, never doubled |

Invariants, checked after every reconciliation and by the chaos suite:

- **I1** A ticket is in exactly one of: Backlog, Ready, In progress with a live session or a recovery
  pending, In review with an open pull request, Done with a merged one, `needs-human` with a comment.
- **I2** No two live sessions share a ticket, worktree or slot; no two pull requests share a head; no
  pull request merges twice.
- **I3** Every worktree belongs to a ticket In progress or In review, or is removed.
- **I4** Every state file parses or is quarantined (section 3).
- **I5** A launch sees the sessions launched earlier in the same poll (#344): `running` is updated at
  each launch and Paths overlap is checked against it.

A **lost session** (`<n>.meta`, no live group, no `.exit`): a verdict file, if any, is read; else the
ticket goes back to Ready with `<n>.recovered` incremented; at `maxConsecutiveFailures` it gets
`needs-human` (as today). **Adoption**: a live session of a dead daemon is tracked until it ends
(the watchdog applies); an ended one is read like any end; neither is put back to Ready while its
verdict can be read. Every `gh` call runs under `timeout` (`serve.callTimeout`, 60 s, graphql 120 s)
inside `gh_retry`, so a hung request cannot freeze the loop: a timeout is a transient failure of that
step and the poll goes on with the steps that need no GitHub.

### Acceptance criteria

- Given `kill -9` at any `fault_point` of one ticket's life (section 7), when `serve` is started and
  polled until quiet, then I1 to I5 hold and the ticket is Done or `needs-human`, with no human
  action and no duplicate pull request. [v1.0]
- Given a pull request MERGED whose ticket is In review (the daemon died after the merge), then the
  next poll sets it Done and cleans its worktree, without a `queued-<pr>` file. [v1.0]
- Given a session that wrote `delivered` and ended while the daemon was down, then the next start
  reads the verdict (ticket In review) instead of putting the ticket back to Ready. [v1.0]
- Given a pushed branch with commits, verdict `delivered`, no pull request, then `serve` opens one,
  and only one when run twice. [v1.0]
- Given the serve dir deleted with tickets In progress and In review, then the next poll recovers the
  first to Ready and reads the second from GitHub; given a `gh` stub that never answers, the poll
  ends within `serve.callTimeout` plus the steps needing no GitHub. [v1.0]

## 3. State files and atomic writes

1. **Write whole, move into place.** Content goes to `<file>.tmp.$$` in the same directory, then
   `sync <file>.tmp.$$` (coreutils, skipped when missing), then `mv -f`. A reader sees the old file
   or the new one. `state_write <file>` (content on stdin) is the only way to write a state file;
   `check` fails on a write under the serve dir that bypasses it.
2. **One lock for read-modify-write.** `state_update` holds `flock -w 10` on `<serve dir>/state.lock`
   (a descriptor of the process, released by the kernel at death: no stale lock exists). The trim of
   `launches` (today `awk > tmp && mv`, racing with the append of `run_launch`), counters and `held`
   use it; a lock timeout is logged and retried next poll.
3. **Appends are one line** (`O_APPEND`, under the pipe-buffer size): `launches` lines are
   `<epoch> <kind>` (`ticket` or `role`, so #355 can count ticket starts).
4. **Readers are tolerant.** A missing, empty or malformed file reads as its default (numbers match
   `^[0-9]+$`); an unparseable one is renamed `<file>.corrupt-<epoch>`, kept 7 days, logged once. A
   `*.tmp.*` older than 1 h is removed at start.
5. **One daemon.** `serve.pid` is checked by pid and `ps -o args=` (as today), replaced atomically.
   What GitHub can rebuild is a cache, never the only copy.
6. **Kernel locks only.** Slot locks (`$XDG_RUNTIME_DIR/senior-mode-slots`) and `state.lock` die with
   their holder; after a reboot the runtime directory is recreated. A git `index.lock` older than
   10 min with no `git` process on the repository is removed by the sweep.

Inventory (serve dir). A atomic (rule 1), L under `state.lock`, S append stream, X written by the
session and read tolerantly.

| File | Content | Rules |
|---|---|---|
| `serve.pid`, `token` | pid; run token (0600) | A |
| `launches` | `<epoch> <kind>`, last hour | S, trim under L |
| `paused`, `breaker` (new) | breaker pause (epoch, reason); trips and last trip | A, L |
| `limit-until` | usage-limit reset epoch | A, L (keeps the later) |
| `held`, `launch-backoff-until` (new) | environment hold (JSON); epoch and startup streak | A, L |
| `ready-last`, `digest` | epoch | A |
| `queued-<pr>`, `rounds-<t>` | caches | A |
| `<n>.meta` (new) | JSON: ticket, role, model, branch, worktree, batch, started, last activity, pr, session id (v1.2) | A, before launch |
| `<n>.sh`, `<n>.prompt`, `<n>.pgid`, `<n>.exit`, `<n>.json` | script, prompt, group, exit code, outcome record | A (script writes `.pgid` and `.exit` by tmp then `mv`) |
| `<n>.outcome` | the session's verdict | X: the prompt asks tmp then `mv`; a first line matching no verdict is ignored |
| `<n>.recovered`, `.transient`, `.resumed`; `.batch`, `.oldpr`, `.red`, `.err`, `.merge`, `.tmux` | counters (A, L); notes (A) | A, L |
| `<n>-<model>.json`, `.log` | session stdout, stderr | S (written by `claude`) |
| `heartbeat`, `version`, `plugin/` (v1.2) | last ping, frozen version, snapshot | A |
| `<common>/senior-mode/runs/<n>/red-tests` | red-tests record (spec 130) | A |

### Acceptance criteria

- Given a daemon killed after the temp file is written and before `mv`, then the old file is intact
  and the next start removes the temp file; given every state file truncated to half, the next poll
  quarantines it, logs it once, applies the default, and the ticket still ends Done or
  `needs-human`. [v1.0]
- Given 20 concurrent appends and 20 trims of `launches`, then no line is lost or torn; `check`
  fails when a `serve` function writes under the serve dir without `state_write`. [v1.0]

## 4. Watchdog

Each poll computes, per live session, an **activity fingerprint** from independent signals, and
keeps the time it last changed in `<n>.meta`:

- the worktree: `HEAD`, a hash of `git status --porcelain`, the newest file mtime (`.git` excluded);
- the process group: cumulative CPU time of its processes (`ps -o cputime=`), and its count of live
  children besides `claude` and the `slot` wrapper;
- the size of `<n>-<model>.log` and, in v1.2, the mtime of the Claude transcript of the session id
  (`$CLAUDE_CONFIG_DIR/projects/<cwd>/<id>.jsonl`), which changes at each message and tool call.

`--output-format json` prints nothing until the end, so session output alone is no signal.

| Threshold | Default | Meaning |
|---|---|---|
| `autonomy.startupMinutes` | 3 | No change at all since launch: hung at startup |
| `autonomy.stallMinutes` | 20 | No change: hung. Above the API client's 10 min request timeout, so a model waiting on a slow answer is not killed |
| `autonomy.sessionTimeout` | 90 (existing) | Absolute maximum, even if still active, so cost is bounded |

**Hung versus long.** A session running a 40-minute test suite is *long*: the group's CPU and children
change the fingerprint at every poll. A session blocked on stdin, a deadlocked dev server (children
alive, no CPU), or a socket that never answers is *hung*: nothing moves for `stallMinutes`. A
thinking model is covered by the 20 min bound.

**Reaction**, for a stall and a timeout alike: log which signals were quiet; `SIGTERM` to the group,
10 s, `SIGKILL` (`run_kill`). The first kill of a ticket's session (`<n>.resumed` is 0) is *transient:
interrupted*: the session is resumed once with a fresh timer (v1.2 `--resume`; v1.0 a fresh session
told to continue from the worktree and pull request); not counted. The second kill is *ticket*:
`needs-human` with the log path and the quiet signals, counted (today's `run_timeout`).

**Zombies and orphans.** Each poll: `Z` processes are ignored by `run_dead`; a live process whose
`/proc/<pid>/cwd` is inside the worktree of a ticket with no live session (Linux; elsewhere skipped
with one log line) gets `SIGTERM` then `SIGKILL`; a group whose leader's command line no longer
holds `/<n>.sh` is never signalled (pid-reuse guard of `run_kill`). Stale locks: section 3, rule 6.

### Acceptance criteria

- Given a stub session that sleeps with no output, children or file change, when `stallMinutes`
  pass on the injected clock, then it is killed and relaunched once, uncounted; a second identical
  stall gives `needs-human` and one breaker count. [v1.0]
- Given a stub whose child burns CPU longer than `stallMinutes` then delivers, then it is never
  killed; given children alive but idle for `stallMinutes`, it is; given a session that keeps
  changing files past `sessionTimeout`, it is killed once and resumed once. [v1.0]
- Given a stub that leaves an orphan in the worktree after its session is killed, then the orphan is
  gone after the next poll. [v1.0]

## 5. Session resume (v1.2)

- **Capture.** At launch the daemon generates a UUID, passes `--session-id <uuid>` to `claude` and
  stores it in `<n>.meta` first. Without that flag the id is read from the `session_id` of
  `<n>-<model>.json` after the end; a killed session then has none and takes the fallback.
- **Resume.** After a transient or interrupted end (network, API, usage limit once reset, watchdog
  first kill, daemon restart): `claude -p --resume <id>` in the same worktree, model, role and slot
  rules, prompt "The session was interrupted by <cause>; continue where you stopped." It counts for
  `sessionsPerHour`, not `ticketsPerHour`; a live group is never resumed.
- **Fallback.** `--resume` fails (`No conversation found`, transcript missing, another
  `CLAUDE_CONFIG_DIR`, unreadable transcript) or no id is known: a fresh session on the same branch,
  original prompt plus a checkpoint built from GitHub and git (commits ahead of base, the pull
  request, statuses and review comments, `git status --short`, last 30 log lines). This is also the
  v1.0 behaviour. Two failed resumes in a row use the fallback.

### Acceptance criteria

- Given a session killed mid-work with its id recorded, then the relaunch shows the `claude` stub
  `--resume <id>` with the same role environment (after the reset when it was a usage limit), and
  the ticket ends delivered. [v1.2]
- Given `--resume` failing, then the stub sees a fresh prompt with the commits, the pull request
  number and the previous log tail. [v1.2]

## 6. Dead-man's switch, self-health, frozen plugin version (v1.2)

**Dead-man's switch.** `notify.heartbeat` `{url, interval}` (default 300 s; empty url disables). At
the end of a completed poll, once `interval` has passed, one request goes to `url` (healthchecks.io
`GET`, or a POST body for ntfy or a webhook) with `state=running|held:<cause>|paused:breaker`, the
running sessions and the last merge time. Silence is the alarm: the service alerts after 3 missed
intervals. A held or paused daemon still pings (it is alive; the hold has its own alert); a stuck
poll sends nothing; a failed ping never fails the poll.

**Self-health before each launch**, cached: disk, RAM and load (today's ceilings), `gh auth status`
(5 min), claude auth (30 min), worktree count under `autonomy.maxWorktrees`, clock jumps over 1 h
(logged, timers recomputed). Red: clean what can be (`clean`, old logs, `git worktree prune`,
`git gc --auto`), re-check, else an environment hold with the exact cause: the proactive twin of
the probes of section 1.

**Frozen plugin version.** A plugin update under a running daemon rewrites the script bash is
reading and changes sessions mid-ticket. At start the daemon copies the plugin to `<serve dir>/plugin/
<version>-<sha>/`, `exec`s the copy, gives it to every session with `--plugin-dir` and records it in
`version`. A newer installed version, seen at the start of a poll, stops launches and drains the
sessions (bounded by `serve.grace`); it is snapshotted and health-checked (`bash -n`,
`senior-mode --version`, `check` on a scratch repository), then the daemon re-`exec`s on it between
tickets; on failure it keeps the old one, alerts once and retries hourly.

### Acceptance criteria

- Given a heartbeat URL on a local stub, then it gets a ping per interval while the daemon polls, one
  with `held:disk` during a hold, and none while a poll is stuck. [v1.2]
- Given `df` at 500 MB before a launch, then logs are cleaned; still under the limit, the launch is
  held with the disk named. [v1.2]
- Given the installed plugin rewritten during a run, then the daemon and its sessions keep their
  snapshot and the next ticket runs on the new version after its health check; if that fails the old
  one keeps running and one alert goes out. [v1.2]

## 7. Chaos suite

**Stub mechanism** (`plugins/senior-mode/bin/tests/test-chaos.sh`, in `check`, offline, on the stubs
of `test-serve.sh`: `gh`, `claude`, `tmux`, `systemctl` on PATH, `SENIOR_MODE_NOW`,
`SENIOR_MODE_SERVE_ONCE`):

- `fault_point <name>` sits at each step boundary of section 2 (`after-meta`, `after-launch`,
  `after-exit-read`, `after-push`, `after-pr-create`, `before-merge`, `after-merge`, `after-done`,
  `during-state-write`, `during-clean`...). It does nothing unless `SENIOR_MODE_TEST=1` and
  `SENIOR_MODE_FAULT=<name>[:<nth>]` are set, then runs `kill -9 $$`.
- The `gh` stub reads `$FIX/gh-mode`: `down`, `5xx:<n>`, `401`, `hang`. The `claude` stub plays
  `startup-settings`, `api-529:<n>`, `limit` (with or without a reset), `enospc`, `silent-hang`,
  `busy-child`, `orphan`, `die-at-start`. `SENIOR_MODE_DF` stands in for `df`,
  `SENIOR_MODE_BACKOFF_JITTER=0` makes delays exact. A reboot kills the daemon and every session
  group, removes the runtime lock directory, keeps the serve dir and starts again.
- After a fault the test polls, advancing the clock, until two polls change nothing (at most 40),
  then asserts I1 to I5 and the case's result; a case that does not settle fails.

| # | Fault | Expected, no human |
|---|---|---|
| F1 | `kill -9` at each fault point (sweep) | I1 to I5, ticket Done or `needs-human` |
| F2 | `kill -9` between `gh pr merge` and the Done write | merge read back, Done, no second merge |
| F3 | network down for 10 polls | backoff spacing, no `needs-human`, no breaker count, delivered |
| F4 | `gh` 502, 429 secondary limit, intermittent | `gh_retry` then transient reaction, no duplicate PR |
| F5 | `gh` 401 then 200 | `held: gh auth`, resumes |
| F6 | `claude` dies at startup 3 times | same model, no escalation, launch pause, delivered |
| F7 | API 529 mid-session | resume (v1.2) or fallback, delivered |
| F8 | usage limit, with and without reset | nothing launches until the reset, delivered |
| F9 | disk full | clean, hold, resume, no ticket failure |
| F10 | red main | ticket launches held, a fix merges, resume |
| F11 | power cut mid-write, truncated state files | old file or quarantine, converges |
| F12 | reboot | adoption or recovery, converges |
| F13 | silent hang; busy long session; orphan | hung killed, resumed once; busy untouched; orphan reaped |
| F14 | session group killed from outside; worktree deleted by hand; stale `index.lock` | lost session recovered once; worktree recreated; lock cleaned |
| F15 | second daemon; stale pid file with a reused pid | refuses; stale replaced |

**Real run per release.** `plugins/senior-mode/bin/tests/chaos-sandbox.sh` (outside `check`: needs
logins) runs on `Sycatle/senior-mode-sandbox` (ADR 0011) with real `claude` and `gh`: `kill -9` of the
daemon and of a session during a merge, the network cut by a blackhole `HTTPS_PROXY` for 5 min, a
small tmpfs for the worktrees to fill the disk, a usage-limit message replayed by a `claude`
wrapper, `systemctl --user restart`, and on a machine that may reboot (linger on) a reboot. It
prints the F table and the board afterwards; the release pull request links the report, and a
missing or failed one blocks the release.

### Acceptance criteria

- `test-chaos.sh` runs in `check` in under 3 minutes and fails when a case does not settle or breaks
  an invariant. [v1.0: F1 to F6, F8 to F11, F13 to F15; v1.2: F7, F12]
- `check` fails when a `fault_point` name in the code is not in the sweep. [v1.0]
- The sandbox script exits non-zero on any failure and reports the cases of its version. [v1.0:
  F1, F2, F3, F6, F8 real; v1.2: all]

## Delivery

| Version | Content | Tickets |
|---|---|---|
| v1.0 | Sections 1 to 4; section 7 (stubbed suite, sandbox subset) | #375 spec and ADR 0021; #377 section 1 (absorbs #334); #379 section 2; #381 section 3; watchdog (4) and chaos suite (7) to be filed from this spec |
| v1.2 | Sections 5 and 6; F7 and F12; the full sandbox run | to be filed from this spec |

Order in v1.0: #381 first (everything writes through it), #377, #379, the watchdog, the chaos suite
last (it asserts the rest). Of the trial findings, #334 is in section 1, #355 is respected by it
(transients count for no cap), #344 is invariant I5; #305, #348 and #350 cause false ticket failures
that poison the breaker, and keep their own tickets.

New keys, documented in `docs/guide/configuration.md` by the ticket that adds them: `serve.backoffBase`
30, `serve.backoffMax` 900, `serve.breakerCooldown` 900 (was 3600), `serve.breakerMax` 14400,
`serve.callTimeout` 60, `autonomy.startupSeconds` 30, `autonomy.minDiskMB` 2048,
`autonomy.startupMinutes` 3, `autonomy.stallMinutes` 20, `autonomy.maxWorktrees` 4 times `parallel`,
`notify.heartbeat` `{url: "", interval: 300}`.

## Out of scope

- Several machines, or two daemons on one repository; agents other than `claude -p`; a dashboard
  for holds and the breaker (`status` shows them); repairing a broken Project schema (spec 176).

## Open questions

- Whether every supported `claude` has `auth status` (else the probe is a one-token ping, a negligible
  but non-zero cost on the subscription).
- The exact messages of an expired login and of a weekly usage limit: the first fixtures come from
  sandbox logs, and the pattern list is meant to grow.
