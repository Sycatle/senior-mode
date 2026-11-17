---
name: commit
description: Make atomic Conventional Commits that each build and pass on their own and explain why. Use whenever committing, and before pushing a branch.
---

# Commits

History is the audit trail (ADR 0005): it merges by rebase, so every commit reaches the default
branch as written.

## One commit

- **Atomic:** one logical change. A refactor and a behaviour change are two commits; so are a
  dependency bump and the code using it.
- **Passes alone:** builds and passes the checks at that commit. Tests travel with the code they cover.
- **Format:** `type(scope): subject` with type in `feat`, `fix`, `docs`, `style`, `refactor`, `perf`,
  `test`, `build`, `ci`, `chore`, `revert`; `!` after the scope for a breaking change, with a
  `BREAKING CHANGE:` footer.
- **Subject:** imperative, lowercase start, no final period, at most 72 characters, says what changes
  for the user or the codebase.
- **Body:** why, when the subject is not enough: the problem, the constraint, the alternative
  rejected. Not a list of files.
- **Footers:** `Refs #n` when useful; the PR carries `Closes #n`.
- Language: types are English keywords; subject and body follow the project language.
- No AI co-author or generated-by trailers.

## Before pushing

- Review `git diff --staged` before each commit; never commit secrets, `.env` files, build output or
  unrelated changes.
- On a branch nobody else has fetched, fold fixes into the commit they belong to
  (`git commit --fixup <sha>`, then `GIT_SEQUENCE_EDITOR=: git rebase -i --autosquash <base>`).
- Never rewrite a pushed shared branch, never force-push the default branch, never `--no-verify`.
