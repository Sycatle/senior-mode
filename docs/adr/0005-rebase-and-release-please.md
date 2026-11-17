---
id: 0005
title: Atomic conventional commits, rebase merges, release-please
status: accepted
spec: 0001
---

## Context

Auditability requires that each commit is one logical change with a stated reason, and that releases
and changelogs follow from history without manual work.

## Decision

- Commits follow Conventional Commits, are atomic (each builds and passes on its own) and explain why
  in the body when the subject is not enough. A `commit-msg` git hook and a CI check enforce the
  format. No AI co-author trailers.
- PRs merge by rebase only; the default branch has linear history and required checks.
- release-please derives versions (semver) and `CHANGELOG.md` from commits.

## Alternatives considered

- **Squash merges:** shorter history, but atomic commits disappear from the default branch.
- **Merge commits:** keep everything, but non-linear and noisy history.

## Consequences

- Commit quality matters on every branch, not just PR titles; the `commit` skill carries the rules.
- Rebase merges require branches to be kept current; `ops` rebases before merging.
