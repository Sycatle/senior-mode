---
name: tdd
description: Drive code changes with tests chosen by the nature of the code - failing test first for logic and bugs, end-to-end scenarios for UI and glue, characterization tests for a refactor-only ticket ("refactor", "refacto", "nettoie"). Use before writing or changing production code, and when fixing any bug ("implémente", "développe", "corrige ce bug").
---

# Test-driven delivery

Tests come from the acceptance criteria of the spec or issue, not from the code.

## By nature of the code

| Code | Rule |
|---|---|
| Logic (rules, calculations, parsing, state, data access) | Write the failing test first, run it, see it fail for the expected reason, then make it pass |
| Bug fix | A regression test reproducing the bug, seen failing, before any fix |
| UI and glue (pages, wiring, configuration) | One end-to-end or integration scenario per acceptance criterion; unit tests only where logic hides |
| Spike or prototype | Exempt while exploring; before merge it is either discarded or covered like the rules above |

## Loop

1. Pick one acceptance criterion. Name the test after it.
2. Red: write the smallest test that expresses it through the test seam named in the spec. Run it.
   Keep the failing output: the PR quotes it.
3. Green: the simplest code that passes. No speculative generality.
4. Refactor with tests green: names, duplication, structure. Behaviour does not change here.
5. Next criterion.

Tests land in the same commit as the code they cover, so every commit passes (ADR 0005).

## Refactor-only ticket

Structure changes, behaviour does not. Behaviour has to change: it is not this mode, split it out.

1. State the goal (what gets simpler) and the invariant (what callers observe: API, outputs, side
   effects, errors).
2. Weak coverage of the touched code: characterization tests first, asserting what it does today,
   bugs included. Green on the unchanged code, committed as `test:` before any change.
3. Small steps (rename, extract, inline, move), tests after each: green or revert. One `refactor:`
   commit per step, each passing alone.
4. A test that has to change means behaviour changed: revert, never edit it to get green.
5. Features, fixes, dependency bumps and unrelated cleanup do not ride along: open a ticket.

Recipes and signs you left the mode: `${CLAUDE_SKILL_DIR}/refactor.md`.

## Good tests

- Test behaviour through public interfaces; a refactor must not break them.
- One reason to fail per test; clear arrange / act / assert.
- Real collaborators when cheap; fakes at boundaries (network, clock, payment provider), not mocks of
  your own internals.
- Deterministic: no sleeps, no order dependence, fixed clocks and seeds.

Avoid: tautological tests that restate the implementation, asserting on private state, snapshot tests
as the only check, tests written after the fact to reach coverage.

A flaky test is a bug: open an issue, never skip or delete it silently.
