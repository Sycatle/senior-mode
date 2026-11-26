---
name: tdd
description: Drive code changes with tests chosen by the nature of the code - failing test first for logic and bugs, end-to-end scenarios for UI and glue, characterization tests for a refactor-only ticket ("refactor", "refacto", "nettoie"). Use before writing or changing production code, and when fixing any bug ("implémente", "développe", "corrige ce bug").
---

# Test-driven delivery

Tests come from the acceptance criteria of the spec or issue, not the code.

## By nature of the code

| Code | Rule |
|---|---|
| Logic (rules, calculations, parsing, state, data access) | Failing test first, seen failing for the expected reason, then make it pass |
| Security (authentication, authorisation, input boundaries, data access, file paths) | Abuse tests first, seen failing: no right, malicious input, another user's record |
| Bug fix | A regression test reproducing the bug, seen failing, before any fix |
| UI and glue (pages, wiring, configuration) | One end-to-end or integration scenario per acceptance criterion; unit tests only where logic hides; a list: one query count at 1 and 10 records, `${CLAUDE_SKILL_DIR}/queries.md` |
| Spike or prototype | Exempt while exploring; discarded or covered as above before merge |

## Loop

1. Pick one acceptance criterion; name the test after it.
2. Red: the smallest test that expresses it, through the seam the spec names. Run it; the PR quotes
   the failure.
3. Green: the simplest code that passes, nothing speculative.
4. Refactor with tests green: names, duplication, structure; no behaviour change.
5. Next criterion.

Tests land in the commit of the code they cover; every commit passes (ADR 0005).

A step retried twice over a constraint the code hides gets a note: `${CLAUDE_SKILL_DIR}/knowledge.md`.

## Refactor-only ticket

Structure changes, behaviour does not; a behaviour change is split out.

1. State the goal (what gets simpler) and the invariant (what callers observe: API, outputs, effects).
2. Weak coverage of the touched code: characterization tests first, asserting today's behaviour,
   bugs included. Green on the unchanged code, committed as `test:` before any change.
3. Small steps (rename, extract, inline, move), tests after each: green or revert. One `refactor:`
   commit per step, each passing alone.
4. A test that has to change means behaviour changed: revert, never edit it to get green.
5. Nothing else rides along: open a ticket.

Recipes, signs you left the mode: `${CLAUDE_SKILL_DIR}/refactor.md`.

## Good tests

- Test behaviour through public interfaces; a refactor must not break them.
- One reason to fail per test; clear arrange / act / assert.
- Real collaborators when cheap; fakes at boundaries (network, clock, payments), not of internals.
- Deterministic: no sleeps, no order dependence, fixed clocks and seeds.
- Fixtures synthetic, never copied from real data.

Avoid: tests restating the implementation, asserting private state, snapshots as the only check,
tests added afterwards for coverage. A flaky test is a bug: open an issue, never skip it.
