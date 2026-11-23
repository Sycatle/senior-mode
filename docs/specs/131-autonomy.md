---
id: 131
title: A daemon delivers every Ready ticket; the human only frames
status: accepted
size: L
paths: ["plugins/senior-mode/bin/senior-mode", "plugins/senior-mode/hooks/**", "plugins/senior-mode/agents/**", "plugins/senior-mode/skills/run/**", "plugins/senior-mode/skills/schedule/**", "plugins/senior-mode/skills/setup/**", "plugins/senior-mode/skills/status/**", "plugins/senior-mode/templates/**", "docs/guide/**"]
adrs: ["0017", "0018", "0019"]
issue: "#131"
---

# A daemon delivers every Ready ticket; the human only frames

## Problem

`run` and `schedule` deliver a batch and stop (ADR 0007, 0012). Between batches nothing moves, a
person must merge, rebase, re-review and move tickets to Ready, and parallel tickets collide on
files, ports and databases. Review independence rests on instructions: a ticket session can set its
own `senior-mode/review`. The target is a machine that works on every Ready ticket by priority, many
at a time, isolated, with the rigour enforced by the tool, and that calls the human only for what
needs them.

## Users and journeys

- **The owner** frames a wave and merges the framing pull request. From then on they read alerts
  and the daily digest, answer `needs-human` items, and otherwise do nothing.
- **A ticket session** delivers one ticket (or a batch of small ones) up to a pull request. It
  cannot set `senior-mode/review`, merge, or touch another ticket's worktree.
- **A reviewer session** (fresh context, Opus) reviews one pull request and is the only role that
  sets `senior-mode/review`.
- **The integrator** merges approved pull requests one at a time and resolves what drifted.

## Acceptance criteria

Orchestration, `senior-mode serve` (#146, #149):

- Given Ready tickets and free slots, when `serve` polls (every `serve.interval` seconds, default
  60), then it starts one ticket session per ticket in `pick` order, records each outcome under
  `.git/senior-mode/serve/`, and keeps polling. `run` is one pass of the same loop that stops when
  its batch is done; `schedule` installs a timer for `run` as today.
- Given `senior-mode serve --install`, then a systemd user unit `senior-mode-serve.service` runs
  `serve` in the repository, restarts on failure, and `systemctl --user stop` stops launching at
  once and lets running sessions finish up to `serve.grace` seconds (default 600) before stopping
  them. `--uninstall` removes the unit.
- Sessions are `claude -p` on the subscription login (ADR 0007), never an API key.

Independent review (#150, #148):

- Given a ticket session (`SENIOR_MODE_ROLE=ticket`), when it posts a commit status whose context is
  `senior-mode/review` (through `gh api .../statuses`, `gh api graphql` or `curl`), then the guard
  denies it. Only `SENIOR_MODE_ROLE=reviewer` may set it.
- Given a pull request In review with CI success and no review status on its head, then `serve`
  starts a reviewer session (Opus) on it. Changes requested: the ticket session resumes on the same
  branch with the findings; after 2 rounds the pull request gets `needs-human`.
- Given a reviewer that cannot run (usage window or rate limit), then the review status stays
  pending and `serve` retries at reset; the author never reviews itself without explicit human
  consent recorded on the pull request (ADR 0019).

Integrator (#151, #173):

- Given approved pull requests, then the integrator merges one at a time by priority: when the
  branch is behind it rebases server-side (`gh pr update-branch --rebase`); when `git range-diff`
  shows any change it re-runs `check`, `publish` and asks a new review; otherwise it carries the
  review status over. A conflict starts an Opus session that resolves it on a `-r2` branch with
  `Supersedes #old`; an unresolved conflict gets `needs-human`.
- Given a pull request that passes the merge policy (ADR 0018) and a repository that allows
  auto-merge, then it is queued with `gh pr merge --auto --rebase --match-head-commit <sha>`;
  otherwise the integrator merges it itself. Merged means `state == MERGED` read back, then Done.

Collisions (#152, #174, #189):

- `setup github` creates a text field Paths on the board; `issue create --paths <globs>` fills it;
  framing copies a spec's `paths` into its tickets.
- Given two Ready tickets whose Paths overlap (a glob of one matches a path prefix of the other),
  then they never run at the same time. A ticket with no Paths runs alone: nothing else starts
  while it runs.
- Given Ready S tickets whose Paths overlap, then `pick` batches up to 3 of them into one session
  and one pull request, one commit and one `Closes #n` each.

Isolation (#153):

- Given a session in slot N (1..`autonomy.parallel`), then it sees `SENIOR_MODE_SLOT=N`, and when
  `.claude/senior-mode.json` has a `slot` command, its `KEY=VALUE` output (for example `PORT`,
  `DATABASE_URL`, a cache dir) is exported into the session. Two sessions never share a slot.

Ready without the human (#154):

- Given a merged framing pull request, then its tickets that pass the Definition of Ready
  (criteria, Size, Priority, Paths) become Ready; the others get `needs-human` with what is missing.
- Given an issue filed by an agent, then it becomes Ready only when S, not high or critical
  security and outside the protected zones; otherwise `needs-human`.

Alerts (#155):

- Given a `needs-human`, a breaker pause or a failed ticket, then the issue or pull request gets the
  label and a mention of `notify.mention` (default: the repository owner), and when
  `notify.webhook` is set a JSON POST `{event, repo, number, url, reason}` is sent.
- Once a day (`notify.digest`, default true) `serve` posts `status --since 24h` as a Project status
  update.

Ceilings (#156):

- At most `autonomy.parallel` sessions and `autonomy.sessionsPerHour` launches (default 6).
- Given a session that hits the subscription usage limit, then `serve` launches nothing (reviewers
  included) until the reset time read from the message, or one hour when none is given.
- Given `autonomy.maxConsecutiveFailures` failures in a row, then the breaker pauses `serve` and
  alerts; `serve --resume` or `serve.breakerCooldown` (default 3600 s) resumes it. It never exits.
- Before each launch, when the load average exceeds the CPU count or available memory is under
  `autonomy.minMemoryMB` (default 1024), the launch waits for the next poll.

Merge policy (#147):

- In `serve`, `autonomy.merge` defaults to on. A pull request merges on its own, whatever its size,
  when `senior-mode/ci`, `senior-mode/review` and `senior-mode/security` are success on the head,
  it has no `needs-human`, the server enforces protection, and it touches no protected zone. L
  pull requests already need the `security` agent's pass (spec 130). Outside `serve`, ADR 0008
  stays the default.

M tickets (#191):

- Given an M ticket, then a separate `test-author` session writes the red tests from the
  acceptance criteria and commits them first; the implementer session may add tests but the guard
  denies editing or deleting the test-author's files, and the review checks they still pass
  unchanged.

Proof (#157):

- Given 6 toy tickets on the sandbox, two touching the same file, when `serve` runs, then every
  ticket ends merged or `needs-human` with a reason, no ticket session set a review status, and the
  board has no drift.

## Out of scope

- A GitHub App identity for agents (#175), spec/code drift (#169), a web dashboard.
- Running sessions on several machines at once.

## Test seams

- `SENIOR_MODE_SERVE_ONCE=1` runs one poll and exits; `claude`, `gh` and `systemctl` are stubbed on
  PATH as in the existing `run` tests; time is injected with `SENIOR_MODE_NOW`.

## Open questions

None.
