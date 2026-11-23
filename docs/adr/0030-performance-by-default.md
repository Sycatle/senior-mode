---
id: 0030
title: Performance rules are on by default, checked on the diff and measured against the base branch
status: accepted
spec: 472
---

## Context

Agents produce code that passes its tests and is slow: a query per list item, a missing index, a
migration that locks a table, a handler that blocks, a page that keeps growing. Nobody asks for
performance in a ticket, so nothing checks it. The rules have to cost little on legacy code (ADR 0022),
must not slow the agents down (spec 474, ADR 0028) and must not depend on the reviewer's attention alone
(ADR 0029, mechanical first).

## Decision (owner, 2026-11-23)

- **On by default.** Each preset ships performance rules for the database, the code and the front end;
  `setup repo` proposes them, and on an existing project validates what is there without overwriting it.
- **Database:** no N+1 (journey tests assert a query count that does not grow with the list, through a
  helper per preset: Prisma, SQLAlchemy, Django, sqlx); an index on every new foreign key, and on every
  column a new query filters or sorts by; no `SELECT *` and no unbounded list in application code;
  migrations linted for locks and destructive changes (`squawk` for Postgres), with expand then contract.
- **Code:** I/O in a loop and blocking calls in a handler are detected on the diff; a performance review
  section covers complexity, caching and memory; a hot path named in a spec has a benchmark, and a
  regression of more than 10% against the base branch blocks the merge.
- **Front end:** the JavaScript of each route has a budget ratcheted on the base branch; Lighthouse
  measures LCP, CLS and blocking time on the preview when the project deploys one.
- **Measured against the base, on the diff.** Benchmarks run on the base and on the head side by side;
  bundle sizes compare with the baseline on the base branch. Untouched code is never measured.
- **Tiered.** Cheap rules run in `check` (tier 2); benchmarks and Lighthouse run in tier 3, in parallel
  with the review, and block the merge only.

## Alternatives considered

- **Review only.** No tooling to maintain, but it depends on what the reviewer notices, and the reviewer
  is a model with the same blind spots as the implementer.
- **`EXPLAIN` on a seeded database.** Catches bad plans the index rule misses, but every project needs a
  realistic seed and a database per slot; the owner did not choose it.
- **Absolute targets** (a fixed bundle size, a fixed benchmark time). Simple to state, but an existing
  project already misses them on day one and a machine change moves benchmarks; comparing with the base
  avoids both.
- **Do nothing.** Performance stays a framing question; regressions are found in production.

## Consequences

- Presets carry more: helpers, linters, bench and build commands per ecosystem, to keep up to date.
- Pattern rules have false positives; they are suppressed with an issue and a reason (ADR 0029) and the
  retro shows which rules are noisy.
- Tier 3 costs machine time on every push that touches a hot path or a route, and noisy benchmarks can
  ask a human (`unstable`).
- A route or a benchmark may only get worse through a visible config change (an explicit budget), which
  the reviewer sees.
