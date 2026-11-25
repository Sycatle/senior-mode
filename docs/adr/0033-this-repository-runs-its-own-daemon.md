---
id: 0033
title: This repository's backlog is delivered by its own daemon, on a frozen release
status: accepted
spec: 0001
supersedes: none (extends 0016)
---
## Context
Until now the owner's interactive session delivered this repository's backlog by hand: it picked the Ready
tickets, opened worktrees, ran subagents, checked and merged. That is what `senior-mode serve` does, with
less ceremony and without the owner's session in the loop. The daemon running on another project found,
in one evening, defects the tests had missed (an environment-failure relaunch loop, a Status reset by the
board, a fine-grained token blind to check runs). Running it here gives that feedback on every ticket.

## Decision
For this repository:
- **The daemon delivers.** `senior-mode serve` runs on the owner's machine and takes the Ready tickets by
  priority, with `autonomy.parallel` 4 and `autonomy.merge` true. The interactive session frames tickets,
  sets them Ready and watches; it does not deliver tickets the daemon can take.
- **A frozen release, not `main`.** The daemon and its sessions run a release tag checked out apart
  (`senior-mode--v<x>`, plugin loaded with `--plugin-dir`), never the working tree it changes. A merge
  cannot change the daemon mid-run; a new release is picked up by restarting it. This holds until
  #395 freezes the plugin version per run.
- **ADR 0016 rigour.** The `fast` profile lifts the independent review for this repository; a pull
  request merges once `senior-mode check` is green. The release pass and the dogfood session stay.

## Alternatives considered
- **Run the daemon on `main`:** always the latest code, but a merge can break the daemon in mid-run.
- **Keep delivering by hand:** the same throughput at best, and the plugin is not exercised for real.
- **Turn the review back on:** stronger, about twice the sessions; left to a later decision.

## Consequences
- A defect in the daemon shows up on this repository first and becomes a ticket.
- What merged after the running release is only exercised once a new release is cut and the daemon
  restarted.
