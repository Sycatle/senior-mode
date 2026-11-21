---
name: docs
description: Keep the living docs current after a merged pull request - README, docs/architecture.md, the user-facing docs/changelog.md, links to new ADRs, and any extra documents the project lists - or summarise changes over a period. Use right after a merge, and on "update the docs", "mets à jour la doc", "what changed this week".
---

# Living docs

Docs rot unless updating them is a step of delivery. After a merge, change only what that change made
stale. Formats, section map and PR body: `${CLAUDE_SKILL_DIR}/reference.md`.

Language: `senior-mode config get language`. Extra documents: `senior-mode config get docs.extra`
(a list of `{path, purpose}`; an error means none).

## After a merge, or on demand

1. List merged PRs newer than the last entry of `docs/changelog.md`
   (`gh pr list --state merged --json number,title,body,url,mergedAt`). Skip PRs from
   `docs/after-pr-*` branches; purely internal ones (tests, CI, refactor) get no changelog entry.
2. Work in a worktree off the default branch, on `docs/after-pr-<last number>`. If a docs PR is
   already open, add commits to its branch instead of opening a second one.
3. README: fix usage and setup that the change made false. Nothing else.
4. `docs/architecture.md`: update the sections the change touches (components, data flow, external
   services). Absent: create it from `${CLAUDE_SKILL_DIR}/../../templates/<language>/architecture.md`.
5. `docs/changelog.md`: one entry per user-visible PR, newest first: what changed for users, in plain
   words, date, PR link. Create it if absent. It is not release-please's `CHANGELOG.md`.
6. Link every new ADR from `docs/architecture.md` (Decisions).
7. For each `docs.extra` entry the change affects: minimal edits, in a separate commit, flagged for
   human review (`needs-human` label, "For human review" in the PR body).
8. Commit `docs: update the docs after #<n>`, push the branch, open a small PR to the default
   branch. Never push to the default branch.

## Never invent

Write only what the diff, the PR, the spec, an ADR or the code states. Anything else stays or
becomes "To confirm" with the question to ask. Name the source of each new fact in the PR body.
Never remove a "To confirm" without a source.

## Digest

"What changed this week": read `docs/changelog.md` only, keep the entries in the period, summarise
them in a few plain lines. Writes nothing; this is how non-technical readers get news.
