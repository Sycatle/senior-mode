---
id: 0007
title: Runs start one headless Claude session per ticket from a shell command
status: accepted
spec: 0001
---

## Context

`run` delivers several tickets in a row, some in parallel. One long Claude session that drives every
ticket through subagents fills its context, cannot run two tickets in separate worktrees with their
own hooks and environment, and stops when the terminal or the session does. A plain script cannot do
the work of a ticket, which needs the agent team. Runs must also work unattended (a timer at night) on
a subscription login, without an API key.

## Decision

- `senior-mode run` is a shell command. It picks the tickets (`pick`), creates a worktree and branch
  per ticket, sets the board, and starts one `claude -p` session per ticket in it, with
  `SENIOR_MODE_RUN=1`, at most `autonomy.parallel` at a time.
- Each session is the senior-mode team for one ticket: subagents inside, the same skills as a manual
  session. It ends by writing one line to the file in `SENIOR_MODE_RUN_OUTCOME`: `delivered`,
  `outgrown: <reason>` or `failed: <reason>`.
- Sessions run in windows of the tmux session `senior-mode-run` when tmux is installed, so a person can
  watch or step in; otherwise in the background. Their logs stay under `.git/senior-mode/runs/`.
- The command, not a model, applies the rules that must not bend: the Opus retry after a Sonnet
  failure (`autonomy.escalate`), the circuit breaker, the merge conditions (ADR 0008), the board
  updates and comments of failed tickets, the final report.
- The `run` skill only confirms the batch with the user, starts the command and explains its report.

## Alternatives considered

- **One orchestrating session with subagents:** no separate worktrees or environments, context grows
  with every ticket, and the bounds depend on a model following instructions.
- **Agent SDK program:** finer control, but an API key and another runtime to install.
- **GitHub Actions:** minutes and secrets that many adopters do not have (ADR 0006).

## Consequences

- A run survives the terminal that started it only under tmux or a timer; the docs say so.
- Session success is checked against GitHub (an open pull request for the branch), not only the
  outcome line.
- `claude` must be on PATH or in `~/.local/bin`, and the user must not be root (Claude Code refuses
  to skip permission prompts for root).
