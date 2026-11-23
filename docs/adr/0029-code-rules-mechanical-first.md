---
id: 0029
title: Code rules are mechanical first and apply to what a pull request adds
status: accepted
spec: 471
---

## Context

senior-mode's code rules are sentences in the principles, the review and the verify skill: no
duplication, errors not swallowed, no disabled checks. Only the model's judgement applies them, and on
long-lived projects developed by agents that judgement drifts from one session to the next. Tools exist
for most of these rules (linters, clone and dead-code detectors, coverage, mutation testing), and a
regular expression on the added lines catches the rest of the frequent cases. Projects adopted with
debt cannot meet a full bar on day one (ADR 0022).

## Decision (owner, 2026-11-23)

- **Mechanical first.** Every rule a tool or a pattern can detect fails `senior-mode check`. The
  reviewer judges only what no tool decides, from explicit checklists (reliability, compatibility,
  design), never from taste.
- **On the diff.** A rule applies to the lines a pull request adds or changes and to new files; existing
  code only never gets worse, through the ratchet of spec 409 §5 and the architecture baseline of #337.
- **Rules live in the plugin, per language.** Each preset names rule packs (`plugins/senior-mode/rules/`);
  `setup` proposes them, and on an existing project the adoption pull request shows what is covered,
  proposed or off, and rewrites nothing without a yes. A project turns a rule off only in
  `.claude/senior-mode.json`, with a written reason; that file is protected, so it reaches a human.
- **A suppression needs a ticket.** A disable, ignore or skip added in the diff carries an issue
  reference and a reason (`-- #123: reason`); `check` fails otherwise, and checks the issue exists when
  GitHub can be reached.
- **Each rule declares its tier and starts as a warning**, as ADR 0028 defines, so the rules never slow
  the agents down more than their budget allows.

## Alternatives

- **Reviewer checklist only.** Fast to ship, no tool to maintain; the result depends on the model of the
  day and drifts, which is the problem.
- **Principles text only.** Cheapest; nothing checks it.
- **Rules on the whole repository.** Simpler to state; an adopted project fails every ticket on debt it
  did not write, or turns the rules off.
- **Scope chosen per project.** One more option, and the full-repository choice has the same failure.
- **A suppression with a reason only.** Lighter; the debt is not tracked, so it is never paid.
- **Every suppression to a human.** Safest; it turns every typed workaround into a wait.

## Consequences

- `check` gains a `code rules` step and outside tools per preset; a missing tool fails with its install
  command instead of passing silently.
- Regex detections give false positives; each has fixtures and an escape that needs an issue and that
  the reviewer lists.
- Proposed linter rules raise counts only in touched files; the ratchet keeps the rest out.
- The rule packs are code the plugin maintains for each language and tool version.
- Agents spend more time on rules; ADR 0028's tiers, cache and budget bound that cost.
