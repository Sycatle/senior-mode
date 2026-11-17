---
name: review
description: Review a pull request on two separate axes, spec conformance and engineering standards, and give a merge verdict. Use when reviewing any pull request or diff, especially from a fresh context before an autonomous merge.
---

# Two-axis review

Review from the diff, the spec and the tests, not from the author's summary.

## Axis 1: spec

- Every acceptance criterion of the linked spec or issue is met and has a test that would fail
  without the change.
- Nothing out of scope was added. Discovered work became a new issue, not part of this PR.
- The spec is updated when code under its `paths` changed (or `Spec-Unchanged:` is justified); ADRs
  exist for hard-to-reverse choices; CLAUDE.md is updated if commands or pitfalls changed.

## Axis 2: standards

- **Simplicity:** the simplest design that meets the criteria (KISS, YAGNI); no speculative
  abstraction.
- **Design:** single responsibility, dependencies pointing inward, no duplication of knowledge.
- **Correctness:** edge cases, errors handled at boundaries, no swallowed errors, no race.
- **Security:** inputs validated, authorisation checked, no secrets, safe queries and rendering.
- **Tests:** test behaviour, deterministic, readable; none skipped or weakened.
- **Readability:** names say intent, comments only for non-obvious constraints, matches the code
  around it.
- **History:** atomic Conventional Commits that each pass (skill `commit`).

## Protected zones

If the diff touches a protected zone from the config (`senior-mode config get protected`):
migrations, security, auth, payments, CI, infrastructure, major dependency upgrades, or an L ticket
or ADR, the verdict can be at best "approve, human merge". Add the label `needs-human`.

## Verdict

Post one PR comment (`gh pr comment`) in the project language:

- **Verdict:** approve, approve with human merge, or changes requested.
- **Spec axis** and **Standards axis**: findings as `file:line`, blocking or not, each with the fix.

Then set the commit status `senior-mode/review` on the head commit: `success` when approved,
`failure` when changes are requested, `pending` for human merge
(`gh api repos/<owner>/<repo>/statuses/<sha> -f state=... -f context=senior-mode/review -f description=...`).
