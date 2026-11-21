---
id: 0009
title: Every skill is a lifecycle step and a team role, with few skills
status: accepted
spec: 0001
---

## Context

senior-mode is the working method of a senior engineering team, packaged as a plugin. Without a rule
for what belongs in it, each new practice (explain, UI review, compliance, refactor, mirroring) became
a skill of its own, with overlapping scope and descriptions that compete to trigger.

## Decision

Every skill is a step of the delivery lifecycle and a role of the team:

| Role | Skills |
|---|---|
| Lead | `triage`, `frame`, `spec`, `adr`, `grill`, `ready` |
| Developer | `tdd` (refactoring is a mode of it), `verify`, `commit` |
| Reviewer | `review`, with explain, UI and dependencies-and-data sections |
| Release and ops | `run`, `next`, `status`, `docs` |
| Learning | `retro` |

A practice that fits no step is a section of an existing skill, or it stays out of the plugin. A new
skill must name the step it serves.

## Alternatives considered

- **A catalogue of specialised skills:** each practice gets its own. Rejected: overlapping scopes,
  poor triggering because descriptions compete, and a maintenance cost that grows with every skill.

## Consequences

- The skill list stays short and predictable; the lifecycle explains where each one acts.
- `explain`, `ui-review`, the licence and personal-data part of `compliance`, and `refactor` are
  reworked into `review` and `tdd`; `docs` becomes generic living documentation.
- Contributors check a new skill against the lifecycle first (CONTRIBUTING.md).
