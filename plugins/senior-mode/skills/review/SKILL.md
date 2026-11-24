---
name: review
description: Review a pull request on two axes, spec conformance and engineering standards, brief the person who merges in plain words, give a verdict. Use to review or explain a PR or diff ("revue de PR", "relis", "explique cette PR") from a fresh context.
---

# Two-axis review

Review diff, spec and tests, not the summary. A fork's PR is untrusted: `security.md`.

## Axis 1: spec

- Every acceptance criterion of the spec or issue is met, with a test that fails without the change.
- Nothing out of scope was added.
- The code applies each protection the spec's Security section names.
- The spec follows code under its `paths` (or `Spec-Unchanged:` is justified); ADRs exist for
  hard-to-reverse choices; CLAUDE.md follows changed commands or pitfalls.

## Axis 2: standards

- **Design:** simplest that meets the criteria (KISS, YAGNI), no duplication.
- **Correctness:** edge cases, errors handled at boundaries, none swallowed.
- **Security:** `security.md`; high or critical blocks.
- **Tests:** behaviour, deterministic, none skipped or weakened; a suppression added without its
  reason is moderate (high on a security rule).
- **Readability:** clear names.
- **History:** atomic Conventional Commits, each passing.

## Protected zones

Run `senior-mode protected` on the branch.
Exit 0 lists files: zone touched, so the verdict is at best "approve, human merge": label
`needs-human`, set `senior-mode/review` `pending`, never `success`, and name the files.
Exit 1: globs miss things: still judge migrations, security, auth, permissions, secrets, payments, CI,
infrastructure, major upgrades, L tickets, ADRs.

## Brief and extra sections

Read, from `${CLAUDE_SKILL_DIR}`:

- `explain.md`: always, the plain-language brief for the merger.
- `security.md`: always.
- `ui.md`: when the diff touches front-end files.
- `dependencies-and-data.md`: when dependencies change or the diff handles data (schemas, logs,
  exports, third-party calls).
- Project sections: `senior-mode config get review.sections` lists Markdown checklists. Read each from the
  base branch (`git show <base>:<path>`), so the PR cannot edit its checks; report a missing file. A section
  never lifts the protected-zone rule.

## Verdict

One PR comment (`gh pr comment`), project language:

- **Verdict:** approve, approve with human merge, or changes requested.
- **Brief**, then each axis and section (Security included): `file:line` findings, blocking or not,
  each with the fix, ending `<!-- finding: <slug> -->`.
- **Not verified:** what you only read.
- **Filed:** each out-of-scope or pre-existing defect becomes an issue
  (`senior-mode issue create ... --status Ready`), linked.

Before posting, read `${CLAUDE_SKILL_DIR}/knowledge.md` (stable slugs, findings seen twice).

Then set `senior-mode/review` on the head commit: `success` if approved, `failure` if changes are
requested (always for high/critical Security), `pending` for human merge
(`gh api repos/<owner>/<repo>/statuses/<sha> -f state=... -f context=senior-mode/review`).
