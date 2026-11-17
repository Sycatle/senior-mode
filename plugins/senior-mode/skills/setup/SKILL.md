---
name: setup
description: Adopt a repository for senior-mode - GitHub board, labels, merge rules and a ruleset on the default branch - safely re-runnable to repair. Use when the user asks to set up, install or adopt senior-mode in a project, or when a senior-mode command reports a missing config.
disable-model-invocation: true
---

# Setup

Safe to rerun: it repairs, never duplicates.

## Before

1. The folder is a git repository with an `origin` remote on GitHub. If not, explain in plain words
   and offer to create one, private by default, never without a yes. GitHub needs a first commit to
   have a default branch: commit what is there, then `gh repo create <name> --private --source . --push`.
2. `gh auth status` succeeds. If the token lacks the `project` scope, ask the user to run
   `gh auth refresh -s project` (it opens a browser) and wait.
3. Ask once: checks before each push only (`local`, free) or also on GitHub Actions (`actions`,
   spends the Actions budget). Then tell the user, in one short table, what will change on GitHub:
   a Project board linked to the repository, labels, rebase-only merges, a ruleset on the default
   branch, in `local` the repository's workflows disabled (files kept), and the files of Repository
   below. Proceed on their yes.

## GitHub

Run `senior-mode setup github --ci <local|actions>`. It:

- finds (cached number, else same title) or creates the Project, links it, ensures the fields
  Status, Priority and Size, keeping options and values already there;
- creates the labels `needs-human`, `needs-info`, `blocked` (and `type:*` on a personal account);
- allows rebase merges only and deletes branches after merge;
- creates or updates a ruleset `senior-mode` on the default branch: pull requests only, rebase,
  `senior-mode/ci` and `senior-mode/review` required, linear history; existing protection is kept;
  an admin can bypass it with `gh pr merge --admin`;
- `local`: disables the repository's workflows (files kept); `actions`: `setup repo` then adds
  `.github/workflows/senior-mode.yml`, which runs the checks and sets `senior-mode/ci`.

## Repository

1. Run `senior-mode setup repo`. With a `package.json` it takes the `node` preset and its
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
