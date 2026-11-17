---
name: spec
description: Write and maintain feature specs in docs/specs with their lifecycle and governed paths. Use when creating a spec for an M or L ticket, when code governed by a spec changes, and when a spec is replaced.
paths: ["docs/specs/**"]
---

# Specs

Every M or L feature has one spec in the repository (ADR 0002). Specs are the durable "what and
why"; GitHub holds the state.

## Create

- File: `docs/specs/NNNN-short-slug.md`, `NNNN` = highest existing number + 1, zero-padded.
- Start from `${CLAUDE_SKILL_DIR}/template.md`. Size M fills Problem, Acceptance criteria, Out of
  scope and Test seams only; size L fills every section.
- Acceptance criteria are Given / When / Then, observable from outside, each one testable. They
  become the tests.
- `paths` lists the globs of code this spec governs; keep it narrow.
- Write in the project language (`senior-mode config get language`), plain words first, technical
  detail in its own section.

## Lifecycle

`draft` → `accepted` → `implemented` → `superseded`.

- `draft` while framing; `accepted` when the user approves (always a human for size L).
- `implemented` in the PR that delivers the last acceptance criterion.
- `superseded` when a new spec replaces it: set `superseded-by: NNNN`, never delete the file.

## Keep it true

- A PR that changes code under a spec's `paths` updates the spec in the same PR, or states
  `Spec-Unchanged: <reason>` in its body. A CI check enforces this.
- Update acceptance criteria when behaviour changes; never let tests and spec disagree.
- Do not create other documentation folders, plans or notes files: state goes to GitHub, decisions to
  ADRs (skill `adr`).
