---
id: 0012
title: Scheduled runs execute on the agent machine with its subscription login
status: accepted
spec: 0001
---

## Context

The delivery plan placed the scheduled `run` in GitHub Actions. That needs an API key or OAuth token
stored as a secret and a budget cap, and many users have no Actions budget at all (ADR 0006).

## Decision

A scheduled `run` is a systemd user timer or a cron entry on the agent machine, launching `claude -p`
with the login of the machine's own Claude subscription. No API key, no budget flag: the batch is
bounded by `autonomy.maxTickets` and the circuit breaker (ADR 0003).

This supersedes the "scheduled run in Actions" part of the plan in spec section 19. It is consistent
with ADR 0006: checks and runs are local by default.

## Alternatives considered

- **Scheduled run in GitHub Actions:** hosted and always on, but needs a secret, an Actions budget and
  a cost cap; contradicts local CI.
- **Cloud scheduled task:** no machine to keep, but the project must be reachable from the cloud.

## Consequences

- The agent machine must be on at the scheduled time, with a non-root user and `claude` resolved
  outside a non-login `PATH`.
- Cost is the subscription's usage, not a metered bill; limits are tickets, not money.
