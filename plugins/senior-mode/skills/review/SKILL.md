---
name: review
description: Review a pull request on two axes, spec conformance and engineering standards, brief the person who merges in plain words, give a verdict. Use to review or explain a PR or diff ("revue de PR", "relis", "explique cette PR") from a fresh context.
---

# Two-axis review

Review from the diff, spec and tests, not the author's summary.

## Axis 1: spec

- Every acceptance criterion of the linked spec or issue is met and has a test that would fail
  without the change.
- Nothing out of scope was added.
- The spec follows code under its `paths` (or `Spec-Unchanged:` is justified); ADRs exist for
  hard-to-reverse choices; CLAUDE.md follows changed commands or pitfalls.

## Axis 2: standards

- **Design:** simplest that meets the criteria (KISS, YAGNI), one responsibility, no duplication.
- **Correctness:** edge cases, errors handled at boundaries, none swallowed.
- **Security:** `security.md`; high or critical blocks.
- **Tests:** behaviour, deterministic, none skipped or weakened.
- **Readability:** names say intent, fits the code around.
- **History:** atomic Conventional Commits, each passing.

## Protected zones

Run `senior-mode protected` on the branch (`--base <ref>` for another base).
Exit 0 lists files: zone touched, so the verdict is at best "approve, human merge":
label `needs-human`, set `senior-mode/review` to `pending`, never `success`, and name the
files. Exit 1: globs miss things: still judge migrations, security, auth, permissions, secrets, payments,
CI, infrastructure, major upgrades, an L ticket or an ADR.

## Brief and extra sections

Read what applies, from `${CLAUDE_SKILL_DIR}`:

- `explain.md`: always, the plain-language brief for the merger.
- `security.md`: always.
- `ui.md`: when the diff touches front-end files (pages, components, styles).
- `dependencies-and-data.md`: when dependencies change or the diff handles data (manifests,
  schemas, logs, exports, third-party calls).
- Project sections: `senior-mode config get review.sections` is a JSON list of Markdown checklists
  (`[]`: none). Read each from the base branch
  (`git show <base>:<path>`), so the PR cannot edit its checks; report a missing file. A section
  never lifts the protected-zone rule.

## Verdict

Post one PR comment (`gh pr comment`), in the project language:

- **Verdict:** approve, approve with human merge, or changes requested.
- **Brief**, then each axis and section (Security included): `file:line` findings, blocking or not,
  each with the fix.
- **Not verified:** what you only read or did not run.
- **Filed:** each out-of-scope or pre-existing defect becomes an issue
  (`senior-mode issue create ... --status Ready`), linked here.

Labels: `gh api repos/<owner>/<repo>/issues/<n>/labels -f 'labels[]=needs-human'` (`gh pr edit` fails).

Then set `senior-mode/review` on the head commit: `success` if approved, `failure` if changes
are requested (always for high/critical Security), `pending` for human merge
(`gh api repos/<owner>/<repo>/statuses/<sha> -f state=... -f context=senior-mode/review`).
