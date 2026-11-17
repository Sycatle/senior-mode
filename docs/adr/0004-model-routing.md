---
id: 0004
title: Pin a model and effort per agent role, escalate on failure
status: proposed
spec: 0001
---

## Context

Inheriting the session model wastes Opus on mechanical work and starves judgement-heavy work when the
session runs a cheaper model. References leave routing to prose or ignore it.

## Decision

Each agent declares its model and effort in its frontmatter:
- Haiku, low effort: `scout` (codebase facts), `ops` (GitHub operations, status).
- Sonnet, medium effort: `researcher`, `test-author`, `implementer`.
- Opus, high effort: `architect` (framing, ADRs, decomposition), `reviewer` (fresh-context review,
  merge verdict).

The implementer escalates to Opus with high effort after 2 failed attempts on the same ticket. The
reviewer is never a cheaper model than the implementer. Test author and implementer are different
agents, so tests are not bent to fit the code.

## Alternatives considered

- **Inherit the session model:** simplest, unpredictable cost and quality.
- **One generalist agent per ticket:** fewer handoffs, but loses independent tests and review.

## Consequences

- Predictable cost: most tokens go to Sonnet, Opus is reserved for decisions and verdicts.
- More agents to maintain; each has a narrow prompt and tool set.
