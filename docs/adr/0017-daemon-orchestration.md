---
id: 0017
title: A daemon orchestrates ticket, reviewer and integrator sessions; run is one pass of it
status: accepted
spec: 131
supersedes: 0007 (in part: the loop), 0012 (in part: the timer is one way to start a pass)
---

## Context

`run` starts one `claude -p` session per ticket and stops when its batch is done (ADR 0007);
`schedule` starts it on a timer (ADR 0012). Nothing reviews, rebases or merges between batches, and
review independence depends on the ticket session not setting its own status.

## Decision

- `senior-mode serve` is a long-running shell loop, installed as a systemd user service. Each poll
  it starts, within the ceilings, ticket sessions for Ready tickets, reviewer sessions for pull
  requests waiting for review, and one integrator pass.
- Each session runs with `SENIOR_MODE_ROLE` (`ticket`, `test-author`, `reviewer`, `integrator`);
  the guard decides what each role may do. Only `reviewer` sets `senior-mode/review`.
- `run` is one pass of this loop that stops when its batch is done; `schedule` keeps its timer.
- Sessions stay `claude -p` on the subscription login, as in ADR 0007.

## Alternatives considered

- **Keep batches on a timer:** the night batch waits for a person to merge and re-review.
- **Agent SDK service:** an API key and another runtime.

## Consequences

- The command, not a model, owns the queue, the roles, the ceilings and the merges.
- One process per repository; its state lives under `.git/senior-mode/serve/`.
