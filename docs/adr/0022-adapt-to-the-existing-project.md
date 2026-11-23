---
id: 0022
title: senior-mode adapts to the project's workflow and holds legacy code to a ratchet
status: accepted
spec: 409
amends: 0005, 0006
---

## Context

senior-mode was built for a project that starts with it: trunk on the default branch, Conventional
Commits, rebase merges, its own ruleset, one check list, and (in `local` mode) the existing workflows
disabled. Most projects that want it already have a branch model, a commit and PR format, a CI, labels,
templates, sometimes a tracker, and code with debt and few tests. Imposing the defaults breaks the
team's habits and doubles its CI; imposing the full quality bar on the old code makes every ticket
fail on debt it did not create. The owner decided on 2026-11-23 (issue #409) that senior-mode adopts
such a project and adapts to it.

## Decision (owner, 2026-11-23)

- **Adapt to the workflow, do not impose one.** `setup` detects the branch model, the commit and PR
  format, the merge method, the CI jobs, the labels and templates and the tracker from the repository
  and GitHub, records them under `workflow` in `.claude/senior-mode.json`, and `run`, `ready` and
  `check` follow them. It asks the owner only when two readings fit the evidence. What it cannot map
  is listed in the adoption pull request. A repository with no `workflow` key behaves as before.
- **Reuse the project's CI.** With `ci.mode: existing`, the project's jobs are the checks they cover,
  the project's required contexts are kept, and the three `senior-mode/*` statuses are added next to
  them. No workflow is disabled or copied.
- **Survey, then validate.** On a legacy project an agent surveys the architecture and writes a map,
  notes, retroactive ADRs, architecture rules and risk zones into one adoption pull request. Nothing
  binds before the owner merges it. Once merged, agents follow the project's conventions before
  senior-mode's defaults, except for security, independent review, a green `check` and tests.
- **Ratchet over a full bar.** Existing debt (lint, coverage, architecture) is measured once and
  frozen in a baseline. New and touched code meets the bar; the baseline only improves and cannot be
  raised. Untested code gets characterization tests before it changes. The debt becomes maintenance
  tickets under the maintenance budget (spec 325 §6.1). An evergreen project has no baseline: full bar.
- Delivery: workflow detection and respect in v1.0; survey, ratchet, characterization and debt
  tickets in v1.1 with the knowledge epic.

This amends ADR 0005 (rebase is the default merge method, not the only one: `workflow.merge`) and ADR
0006 (`ci.mode` gains `existing`; `local` and `actions` are unchanged).

## Alternatives considered

- **Impose senior-mode's workflow and migrate the project:** one model to test and document, but a
  team that must change its branches, commit format and CI before the first ticket will not adopt it,
  and a migration touches every contributor. Rejected: senior-mode is a guest in the repository.
- **Detect nothing, configure everything by hand:** simple to build, but a long list of keys that
  setup used to fill and the owner now must know. Detection with a report of what is unmapped gives the
  same result with a review step, and a missing key keeps today's behaviour.
- **Add senior-mode's own CI next to the project's:** no mapping work, but two sets of jobs for the
  same lint and tests, double cost, and two answers when they disagree. Rejected for `existing`; the
  parallel `local` and `actions` modes stay for projects with no CI.
- **Full bar from day one on legacy code:** a single rule, but the first ticket fails on thousands of
  pre-existing findings, so either the bar is switched off or no ticket merges. Rejected.
- **Fix the debt first, then adopt:** a clean start, but a long project before any benefit and a
  risk of large untested rewrites. The ratchet delivers value at once and lets the budget pay the
  debt down.
- **A per-line suppress file (`eslint-disable`, `# noqa`) for the old findings:** needs no baseline,
  but edits every old file, hides the debt in the code and does not cover coverage or architecture.
  Rejected; the baseline is one file with counts.
- **Let the agent follow senior-mode's defaults and the project's conventions equally:** where they
  differ, the agent picks at random and reviews argue. The order is fixed: project first, with security,
  review and verification as the exceptions that never yield.
- **Survey without owner validation:** faster, but retroactive ADRs record a reason the code does not
  state, and a wrong note misleads every later agent. The adoption pull request is the check; a `low`
  confidence ADR stays `proposed`.

## Consequences

- More surface in `setup`, `run`, `check` and the hooks, each reading `workflow` first; the fixtures
  of the tests must cover trunk, an integration branch, gitflow and ticket-prefix commits.
- Detection can be wrong; the report lists evidence and `assumed` values, the owner corrects the key,
  and a rerun keeps hand edits.
- A project on `existing` CI gets `senior-mode/ci` later (it waits for the project's jobs) than one
  on `local`; a job that never reports keeps the status pending, and `check` names it.
- The baseline files become protected paths; a legacy project's debt is visible and ranked instead of
  silently tolerated, and shrinks only through merged tickets.
- Retroactive ADRs and notes add files to review; they are capped and validated once.
