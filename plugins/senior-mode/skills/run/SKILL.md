---
name: run
description: Deliver up to N Ready tickets on their own, each in a headless session in its own worktree, then report. Use when the user asks for an autonomous run - "run", "lance", "lance le run", "enchaîne en autonomie", "livre les tickets tout seul", "deliver the backlog on your own".
disable-model-invocation: true
---

# Autonomous run

`senior-mode run` does the work: it picks the tickets, starts one headless `claude -p` session per
ticket in its own worktree (in the tmux session `senior-mode-run` when tmux is installed), waits for
them and prints a report. Your part is to confirm the batch, start it and explain the result.

## Before

1. `senior-mode config get language` gives the language to answer in (`en` if it fails).
2. Read `autonomy.maxTickets`, `autonomy.parallel` and `autonomy.merge` with `senior-mode config get`,
   and list the tickets with `senior-mode pick --max <N>`. No Ready ticket: say so, suggest
   `/senior-mode:ready` or `/senior-mode:frame`, stop.
3. Confirm with the user in one question: the tickets, N, P (how many at a time), and whether the run
   merges (`autonomy.merge`; off means it stops at reviewed pull requests). Change N or P only for
   this run with `--max` and `--parallel`; a lasting change goes in `.claude/senior-mode.json`.

## Run

`senior-mode run --max <N> --parallel <P>`, in the background when your harness allows it: a ticket
takes minutes to an hour. Tell the user where to watch: `tmux attach -t senior-mode-run` (one window
per ticket), or `senior-mode status --watch` in another terminal.

Do not edit files, push or merge yourself during the run: the sessions and the command do it, inside
the guardrails (self-protection, Bash guard, protected zones, circuit breaker).

## After

Turn the report into plain words, in the configured language, in this order:

1. Merged, and what users can now do.
2. Waiting for a human: each pull request and the reason (merging off, review not green,
   `needs-human`, no branch protection), with what to do ("read and merge #42").
3. Failed and why, in one sentence each; the ticket is back in Backlog with a comment, its branch kept.
4. Not started, and why the run stopped early when it did (failures in a row, a ticket that outgrew
   its size).

Never invent a figure the report does not give. The session logs are in the folder the command
printed at start; point to it when something failed without a clear reason.
