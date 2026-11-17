---
id: 0002
title: GitHub holds state, the repository holds specs and decisions
status: proposed
spec: 0001
---

## Context

Workflow kits scatter plans, specs and ledgers in ad-hoc folders that rot. The target users need an
auditable trail and a roadmap readable by non-developers.

## Decision

- **State** (what is planned, in progress, done, by priority and milestone) lives only in GitHub:
  one Project (v2) with fields Status, Priority and Size; native milestones, sub-issues, issue
  dependencies, and issue types when available (type labels otherwise).
- **Durable knowledge** lives only in the repository: every M and L feature has a spec in
  `docs/specs/` with a lifecycle (`draft`, `accepted`, `implemented`, `superseded`) and the code
  `paths` it governs; decisions are ADRs in `docs/adr/`; project principles are a section of
  `CLAUDE.md`, not a separate constitution file.
- No backlog, plan or journal file is created by the plugin.
- CI enforces it: a PR that touches a spec's paths updates the spec or justifies why not; the spec
  index is generated and checked.

## Alternatives considered

- **Specs in issues only:** lightest, but not versioned with the code.
- **Hybrid (spec in the issue for M, file for L):** fewer files, but two places to look.
- **Separate constitution file (spec-kit):** more room, one more document to keep in sync.

## Consequences

- Every change traces commit → PR → issue → spec → ADR.
- More files than an issues-only approach; the drift check and generated index keep them honest.
