---
id: 0018
title: In daemon mode everything green merges on its own, except protected zones
status: accepted
spec: 131
supersedes: 0008 (in part: the default of autonomy.merge under serve)
---

## Context

ADR 0008 keeps merging off by default so a person reads every change. Under `serve` the human only
frames: a queue that waits for a person to merge stops the daemon. Spec 130 already requires the
`security` agent on L pull requests and protected zones.

## Decision

- Under `serve`, `autonomy.merge` defaults to on (a repository may still set it to false).
- A pull request merges on its own, whatever its size, when `senior-mode/ci`, `senior-mode/review`
  and `senior-mode/security` are success on the head commit, it has no `needs-human` label, the
  server enforces protection, and the command finds no protected zone among its changed files.
- A protected zone, a high or critical security finding or `needs-human` waits for the human.
- Outside `serve`, ADR 0008 is unchanged.

## Alternatives considered

- **S and M only, L waits:** a size is an estimate, not a risk measure (ADR 0008); L already has the
  mandatory security pass.
- **S only:** the daemon would stop at most tickets.

## Consequences

- The protected zones are the one place where the owner must keep the list current.
- The daily digest lists what merged, so the owner can read after the fact.

## Note (2026-11-24, #523)

Amended by [0032](0032-local-protection-on-github-free.md): "the server enforces protection" also holds when `github.protection` is
`local`, where senior-mode requires the three statuses and an up-to-date branch itself and an audit reports direct pushes.
