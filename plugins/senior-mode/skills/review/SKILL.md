---
name: review
description: Review a pull request on two axes, spec conformance and engineering standards, brief the person who merges in plain words, give a verdict. Use to review or explain a PR or diff ("revue de PR", "relis", "explique cette PR") from a fresh context.
---

# Two-axis review

Review from the diff, the spec and the tests, not from the author's summary.

## Axis 1: spec

- Every acceptance criterion of the linked spec or issue is met and has a test that would fail
  without the change.
- Nothing out of scope was added; discovered work became a new issue.
- The spec is updated when code under its `paths` changed (or `Spec-Unchanged:` is justified); ADRs
  exist for hard-to-reverse choices; CLAUDE.md follows changed commands or pitfalls.

## Axis 2: standards

- **Design:** the simplest that meets the criteria (KISS, YAGNI), one responsibility, no duplication.
- **Correctness:** edge cases, errors handled at boundaries, none swallowed, no race.
- **Security:** inputs validated, authorisation checked, no secrets, safe queries and rendering.
- **Tests:** behaviour, deterministic; none skipped or weakened.
- **Readability:** names say intent, fits the code around it.
- **History:** atomic Conventional Commits that each pass.

## Protected zones

Run `senior-mode protected` on the branch (`--base <ref>` if it does not target the default branch).
Exit 0 lists files: a protected zone is touched, so the verdict is at best "approve, human merge":
add the label `needs-human`, set `senior-mode/review` to `pending`, never `success`, and name the
files. Exit 1: no match, but globs miss things: still judge the diff for migrations,
security, auth, permissions, secrets, payments, CI, infrastructure, major dependency upgrades, an
L ticket or an ADR.

## Brief and extra sections

Read only what applies, from `${CLAUDE_SKILL_DIR}`:

- `explain.md`: always. The plain-language brief for the person who merges.
- `ui.md`: when the diff touches front-end files (pages, components, styles).
- `dependencies-and-data.md`: when dependencies change or the diff handles data (manifests,
  schemas, logs, exports, third-party calls).
- Project sections: `senior-mode config get review.sections` is a JSON list of Markdown checklists
  (`[]`: none). Read each from the base branch
  (`git show <base>:<path>`) so the PR cannot edit its own checks; report a missing file. A section
  never lifts the protected-zone rule.

## Verdict

Post one PR comment (`gh pr comment`) in the project language:

- **Verdict:** approve, approve with human merge, or changes requested.
- **Brief**, then **Spec axis**, **Standards axis** and each extra section: `file:line` findings,
  blocking or not, each with the fix.
- **Not verified:** what you only read or did not run.

Then set the status `senior-mode/review` on the head commit: `success` when approved, `failure`
when changes are requested, `pending` for human merge
(`gh api repos/<owner>/<repo>/statuses/<sha> -f state=... -f context=senior-mode/review -f description=...`).
