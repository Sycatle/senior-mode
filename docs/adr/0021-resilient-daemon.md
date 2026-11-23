---
id: 0021
title: The daemon classifies failures, reconciles from GitHub and resumes instead of restarting
status: accepted
spec: 373
amends: 0017
---

## Context

ADR 0017 makes `serve` a long-running loop that counts every failed session toward one circuit
breaker, keeps its state in files of `.git/senior-mode/serve/`, and recovers a lost ticket by putting
it back to Ready. The local trial of 2026-11-23 showed the cost: a startup message counted as a
model failure and escalated to Opus (#334), a delivered verdict thrown away by a restart, a breaker
paused a flat hour by problems that were not the tickets' (an outage looks like three bad tickets),
and no test that kills the daemon mid-step. A daemon meant to run unattended for weeks has to survive
crashes, outages, reboots and bad environments without a human and without leaving inconsistent state.

## Decision (owner, 2026-11-23)

- **Classify, then react.** Every session end is classified as *transient* (network, API 5xx and 529,
  startup, usage limit), *environment* (dependency install, disk full, red main, expired auth) or
  *ticket* (a real failure). Transient: resume with backoff, nothing counted. Environment: pause
  every launch with the exact diagnosis and resume by itself once the probe is green. Ticket:
  escalate then `needs-human`, as ADR 0014 and 0017. Only a ticket failure counts toward the breaker,
  whose pause grows exponentially (15 min to 4 h) instead of a fixed hour.
- **GitHub is the truth, local files are a cache.** At start and every poll the daemon reconciles
  sessions, slots, locks and worktrees with the board, branches, pull requests and commit statuses.
  Each step is idempotent, so a `kill -9` at any point leaves a state the next poll repairs.
  State files are written atomically (temp file, `mv`) under a lock.
- **Resume over restart.** An interrupted session resumes with `claude --resume <session-id>` in its
  worktree (v1.2), falling back to a fresh session built from the pull request and the branch (the
  checkpoint, v1.0). A watchdog kills a session with no sign of activity or past its maximum time and
  resumes it once.
- **Proof and monitoring.** A chaos suite injects the faults on stubs in `check` and for real on the
  sandbox at each release; a dead-man's switch heartbeat, a self-health check before each launch and a
  plugin version frozen per run follow in v1.2.
- The sections, thresholds and acceptance criteria are in spec 373. ADR 0017 stands for everything
  it does not touch: the loop, the roles, `run` as one pass.

## Alternatives considered

- **Let systemd restart the daemon and nothing else:** it restarts a process, not a ticket: the
  verdicts, the half-pushed branches and the paid sessions of the crashed daemon are lost or
  redone, and it does not tell an outage from a bad ticket.
- **A local journal or database as the truth (write-ahead log, SQLite):** a second source of truth
  that drifts from GitHub after a crash or a manual edit. GitHub already is the durable, shared,
  inspectable record, so local files stay a cache of intent.
- **Count every failure toward the breaker, with a longer pause:** an outage then pauses the work
  as long as a bad ticket would, and tickets get blamed for the network. Classification keeps the
  breaker meaning "the tickets are failing".
- **Always start a fresh session after an interruption:** simple, but it pays for the context again
  and loses what the model knew; kept as the fallback, since a transcript can be missing.
- **Judge a hung session by its output alone:** `--output-format json` prints nothing until the
  end. Independent signals (worktree changes, process CPU and children, transcript) tell a long
  session from a hung one without depending on one file format.
- **An external orchestrator (a queue, a workflow engine):** a second runtime and service to keep
  alive for what a shell loop with GitHub as its state already does.

## Consequences

- `serve` gains `serve_classify`, a hold on environment causes, `state_write` and `state_update`,
  `<n>.meta`, a watchdog and fault points; `serve.breakerCooldown` defaults to 900 s, the base of an
  exponential.
- Three alert events join the webhook: `environment`, `recovered`, and the heartbeat for silence.
- A transient never reaches `needs-human`, so a long outage ends with the work finished, not with a
  board of labelled tickets.
- The classifier relies on message patterns of `claude` and `gh`; they are data in one function and
  will need a fixture each time a message changes.
