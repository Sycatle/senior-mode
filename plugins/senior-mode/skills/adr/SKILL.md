---
name: adr
description: Record architecture decisions as ADRs in docs/adr, one decision each, never rewritten once accepted. Use when a choice is hard to reverse, chooses between real alternatives with lasting consequences, or changes a previous decision.
paths: ["docs/adr/**"]
---

# Architecture Decision Records

## When

Write an ADR when a decision is hard or costly to reverse: a framework, a datastore, a public
interface, a data model, an authentication scheme, a hosting or CI model, a convention every file
follows. Every L ticket has at least one.

Do not write one for reversible, local choices (a helper's name, a library swapped in an hour). The
commit message is enough there.

## How

- File: `docs/adr/NNNN-short-slug.md`, `NNNN` = highest existing number + 1.
- Start from `${CLAUDE_SKILL_DIR}/template.md`. One decision per ADR.
- At least two real alternatives with their trade-offs, including "do nothing" when it is credible.
- Consequences include the bad ones.
- Link both ways: the spec lists the ADR in `adrs`, the ADR names its spec.
- Write in the project language, plain words; a non-developer must understand the Decision section.

## Status

`proposed` → `accepted` → `superseded`.

- `proposed` until a human accepts it; implementation that depends on it waits.
- An accepted ADR is never edited except its status and `superseded-by`. To change a decision,
  write a new ADR that supersedes it, and set `superseded-by: NNNN` on the old one.
