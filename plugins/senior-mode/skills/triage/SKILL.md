---
name: triage
description: Classify a request as S, M or L before any work and apply only the ceremony that size requires. Use at the start of every feature request, bug report, refactor or idea, and again when a ticket grows during work ("trie", "c'est quelle taille ?", "c'est gros ?").
---

# Triage

Decide the size first. It sets everything else: issue, spec, ADR, review depth. Never add ceremony
the size does not require, never skip ceremony it does.

## Criteria

Any single criterion is enough for the larger size.

| Size | Criteria |
|---|---|
| S | One module, under ~50 changed lines, no new dependency, no interface change, trivially reversible |
| M | Bounded feature or refactor, under ~400 changed lines, may add a dependency or change an internal interface |
| L | New subsystem, data migration, public interface (API, schema, file format), hard-to-reverse choice, or over ~400 lines |

Generated code and lockfiles do not count toward line estimates.

## Ceremony

| Size | Required |
|---|---|
| S | Branch and PR; no issue or spec. A bug fix still gets a regression test first. |
| M | Issue with acceptance criteria, light spec in `docs/specs/` (skill `spec`), TDD, PR closing the issue. |
| L | `/senior-mode:frame`: alternatives, ADR(s) (skill `adr`), full spec, epic issue split into sub-issues of size M or less. A human accepts the spec and ADRs before implementation starts. |

## Output

State the size and the criterion that decided it, in one line, in the project language
(`senior-mode config get language`; without a config, the language of the request). Example:
`Size M: adds a dependency (zod).`

When unsure between two sizes, take the larger one and say why.

## A ticket that grows

If work reveals the ticket is larger than its size (more lines, a new interface, a migration), stop
before going further. Report what was found, propose a split into tickets of the right size, and
update the `Size` field (`senior-mode item set <issue> Size <S|M|L>`). Do not finish an L inside an
M ticket.
