---
id: 0031
title: Three verbs for the human - frame, go, status
status: accepted
amends: 0007, 0017
---

## Context

The plugin advertised six commands to the human (`setup`, `frame`, `next`, `status`, `run`, `retro`) plus a script
with some thirty sub-commands. The surface audit of #318 (`docs/surface-audit.md`) found that `next` and `run` are two
ways to say "move the project forward", that `serve` (ADR 0017) made `run` a special case, and that `setup` and `retro`
are needed at known moments rather than chosen. The owner decided on 2026-11-23 (#319) that the human needs only three.

## Decision (owner, 2026-11-23)

- **`/senior-mode:go` depends on state.** When `serve` runs in the repository, `go` attaches: it says what needs the
  user and where to watch, and delivers nothing itself. Otherwise it delivers the top Ready ticket in the session with
  the user in the loop (the former `next`). `go auto` starts the daemon (`serve --install`) after the user confirms
  `autonomy.parallel` and `autonomy.merge`.
- **`next` and `run` become hidden aliases for one release.** They stay callable, say the new name and run `go`
  (`run` runs `go auto`); the guide and the READMEs no longer list them; the next release removes them. The
  `senior-mode run` script command stays, for a bounded batch without the daemon.
- **`setup` and `retro` start on their own.** The first `go` in a repository without `.claude/senior-mode.json` runs
  `setup`. `status` reports a retro due a week after the last one (a mark in `.git/senior-mode/retro-last`, started at the
  first status) and the skill offers it. Both stay callable.
- **The trust gate stays locked.** Confirmed with ADR 0027: no lever, and no verb, makes an external pull request count
  as internal (ADR 0024).

## Consequences

- `status --json` gains `serve` (`running`, `pid`, from `.git/senior-mode/serve/serve.pid`) and `retro` (`lastDays`,
  `due`), and its text output a line for each.
- The discipline skills and the agents are unchanged: they were never advertised as commands.
- Someone who types `/senior-mode:next` or `/senior-mode:run` during the transition is told the new name.
