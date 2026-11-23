---
id: 0019
title: When the independent reviewer cannot run, the review waits
status: accepted
spec: 131
---

## Context

The reviewer session can be blocked by a usage window or a rate limit. Letting the author review
itself keeps the queue moving but removes the independence the review exists for.

## Decision (owner, 2026-11-22)

- Without explicit human consent: `senior-mode/review` stays pending and `serve` retries the
  reviewer at the reset.
- With explicit consent recorded on the pull request: the author may review, the review comment says
  so, and an issue is filed for an independent re-review afterwards.

## Consequences

- A long usage window delays merges; the digest shows the pull requests waiting for review.
