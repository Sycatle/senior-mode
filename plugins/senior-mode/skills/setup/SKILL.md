---
name: setup
description: Adopt a repository for senior-mode - GitHub board, labels, merge rules and a ruleset on the default branch - safely re-runnable to repair. Use when the user asks to set up, install or adopt senior-mode in a project, or when a senior-mode command reports a missing config.
disable-model-invocation: true
---

# Setup

Idempotent: running it again creates nothing twice and repairs what is missing.

## Before

1. The folder is a git repository with an `origin` remote on GitHub. If not, explain in plain words
   and offer to create one, private by default, never without a yes. GitHub needs a first commit to
   have a default branch: commit what is there, then `gh repo create <name> --private --source . --push`.
2. `gh auth status` succeeds. If the token lacks the `project` scope, ask the user to run
   `gh auth refresh -s project` (it opens a browser) and wait.
3. Tell the user, in one short table, what will change on GitHub: a Project board linked to the
   repository, labels, rebase-only merges, a ruleset on the default branch, and the files of
   Repository below. Proceed on their yes.

## GitHub

Run `senior-mode setup github`. It:

- finds (cached number, else same title) or creates the Project, links it, ensures the fields Status (Backlog, Ready, In progress, In review, Done), Priority (P0 now, P1 next, P2 later,
  P3 someday) and Size (S, M, L), keeping options and values already there;
- caches every id in `.claude/senior-mode.json`, other keys untouched;
- creates or updates the labels `needs-human`, `needs-info`, `blocked`, and on a personal account the
  type labels `type:feature|bug|task|chore` (organizations use issue types);
- allows rebase merges only and deletes branches after merge;
- creates or updates a ruleset `senior-mode` on the default branch: pull requests only, rebase,
  `senior-mode/ci` and `senior-mode/review` on an up-to-date branch, linear history, no force-push or
  deletion; existing protection is left as is; an admin can bypass it with `gh pr merge --admin`.

GitHub refuses rulesets on a private repository of a free plan: it says so and goes on.

## Repository

1. Run `senior-mode setup repo`. With a `package.json` it takes the `typescript` preset and its
   scripts; otherwise ask once how to lint, typecheck, test and build, and rerun with one
   `--command lint="<cmd>"` per answer. It adds checks, git hooks, `CLAUDE.md` Principles, PR and
   issue templates, permissions and release-please, keeping what exists.
2. If it prints `missing:`, propose a tool for each (Biome to lint, Vitest to test), added in its
   own commit only on a yes; then rerun it.
3. If it created `CLAUDE.md`, fill the skeleton from the scout agent's commands, code map and
   pitfalls. If it reports over 80 lines, propose cuts to the user.

## Report

Summarise what the commands printed in plain words, in the project language, with the Project URL (`gh project view <number> --owner <owner> --web` opens it). On failure, quote the error
and the command to retry; setup is safe to run again.
