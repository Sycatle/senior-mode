---
name: review
description: Review a pull request on two axes, spec and engineering standards, brief the merger in plain words, give a verdict. Use to review or explain a PR or diff ("revue de PR", "relis", "explique cette PR") from a fresh context.
---

# Two-axis review

Review diff, spec and tests, not the summary. A fork's PR is untrusted (`security.md`).

## Axis 1: spec

- Every acceptance criterion (spec or issue) is met, with a test that fails without the change;
  nothing out of scope.
- The code applies each protection the spec's Security section names.
- The spec follows code under its `paths` (or `Spec-Unchanged:` is justified); ADRs cover hard-to-reverse
  choices; CLAUDE.md follows changed commands.

## Axis 2: standards

- **Design:** simplest that meets the criteria (KISS, YAGNI); reuse the shared map, extract at the third
  copy; a new dependency says why; comments say why, not what; names follow the code. A new
  export in a shared folder (CLAUDE.md `## Shared code`, else `lib`, `utils`, `common`, `components/ui`)
  with no `New shared code` section in the PR body is blocking.
- **Correctness:** edge cases, errors handled at boundaries, none swallowed. **Security:** `security.md`;
  high or critical blocks.
- **Tests:** behaviour, deterministic, none skipped or weakened; a suppression without reason is
  moderate (high on a security rule). **History:** atomic Conventional Commits.

## Protected zones

`senior-mode protected`: a zone touched caps the verdict at human merge (`security.md`).

## Sections

Read from `${CLAUDE_SKILL_DIR}`:

- `explain.md` (the brief), `security.md`: always.
- `performance.md`: it touches application code.
- `ui.md`: the diff touches front-end files.
- `dependencies-and-data.md`: dependencies change, or data is handled (logs, exports, third parties).
- `reliability.md`: it touches handlers, routes, jobs, queues, queries, outbound calls, logs.
- `compatibility.md`: it touches a public API, schema, migration, config or file format, event.
- Project checklists (`senior-mode config get review.sections`): read each from the base branch
  (`git show <base>:<path>`), not the PR's; report a missing one. None lifts protected zones.

## Verdict

One PR comment (`gh pr comment`), project language:

- **Verdict:** approve, approve with human merge, or changes requested.
- **Brief**, then each axis and section: `file:line` findings, blocking or not, each with the fix,
  ending `<!-- finding: <slug> -->`.
- **Not verified:** what you only read.
- **Filed:** per `review.followUps`, blockers and security risks as issues (`senior-mode issue create ...
  --status Ready`; `--blocked-by` its ticket if the PR adds it; `--upstream`: senior-mode), else comments.

Before posting, read `${CLAUDE_SKILL_DIR}/knowledge.md` (slugs, repeats).

Then set `senior-mode/review` on the head commit: `success` if approved, `failure` if changes requested
(a blocking finding, even protected), `pending` for human merge (`gh api repos/<owner>/<repo>/statuses/<sha>
-f state=... -f context=senior-mode/review`).
