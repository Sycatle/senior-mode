---
id: 0014
title: A ticket failing on Sonnet is retried once on Opus before it counts as a failure
status: accepted
spec: 0001
---

## Context

ADR 0004 escalates the implementer to Opus after 2 failed attempts inside a ticket. In a run, a ticket
that still fails after that stops a batch quickly: 2 consecutive failures trip the circuit breaker
(ADR 0003), although a stronger model might have delivered it.

## Decision

A ticket that fails on Sonnet is retried once on Opus before it counts as a failure for the circuit
breaker. Controlled by `autonomy.escalate`, default `true`; set to `false` to fail directly. The
reviewer stays at least as strong as the implementer (ADR 0004).

## Alternatives considered

- **No escalation in runs:** cheapest, but the breaker trips on tickets Opus could finish.
- **Opus from the start:** best success rate, but spends Opus on mechanical work (ADR 0004).

## Consequences

- A failed ticket costs at most one extra Opus attempt.
- The run report states which tickets were escalated, so the cost is visible.
