---
name: setup
description: Adopt a repository for senior-mode - GitHub board, labels, merge rules and a ruleset on the default branch - safe to rerun, repairs. Use when the user asks to set up, install or adopt senior-mode in a project, or when a senior-mode command reports a missing config.
disable-model-invocation: true
---

# Setup

Safe to rerun: it repairs.

## Before

1. The folder is a git repository with an `origin` remote on GitHub. If not, offer to create one,
   private by default, never without a yes. GitHub needs a first commit: commit what is there, then `gh repo create <name> --private --source . --push`.
2. `gh auth status` succeeds. If the token lacks the `project` scope, ask the user to run
   `gh auth refresh -s project` and wait.
3. Ask once: checks before each push only (`local`, free) or also on GitHub Actions (`actions`,
   spends the Actions budget). Then tell the user, in one short table, what will change: a Project
   board, labels, rebase-only merges, a default-branch ruleset, in `local` the workflows disabled
   (files kept), and the Repository files below. Proceed on their yes.

## GitHub

Run `senior-mode setup github --ci <local|actions>`. It:

- finds or creates the Project, links it, ensures the fields Status, Priority and Size, keeping
  existing options;
- creates the labels `needs-human`, `needs-info`, `blocked` (and `type:*` on a personal account);
- allows rebase merges only, deletes merged branches;
- creates or updates a ruleset `senior-mode` on the default branch: pull requests only, rebase,
  `senior-mode/ci` and `senior-mode/review` required, linear history; other protection kept;
  an admin can bypass it with `gh pr merge --admin`. If it prints `protection: NOT enforced`
  (private repo on GitHub Free), relay it and get an acknowledgement;
- `local`: disables the repository's workflows (files kept); `actions`: `setup repo` then adds
  `.github/workflows/senior-mode.yml`: checks, `senior-mode/ci`, releases. If it prints
  `releases:`, relay it (the release PR needs a `RELEASE_PLEASE_TOKEN` secret to get CI).

## Repository

1. Run `senior-mode setup repo`. With a `package.json` it takes the `node` preset and its
   scripts; otherwise ask once how to lint, typecheck, test and build, and rerun with one
   `--command lint="<cmd>"` per answer. It adds checks, git hooks, `CLAUDE.md` Principles, PR and
   issue templates, permissions and release-please, keeping what exists.
2. If it prints `missing:`, propose a tool for each (Biome to lint, Vitest to test), added in its
   own commit on a yes; then rerun it.
3. If it created `CLAUDE.md`, fill the skeleton from the scout agent's commands, code map and
   pitfalls. If it reports over 80 lines, propose cuts.
4. Offer a status line (ticket, last check, run); it replaces the user's own in this project. On a
   yes, run `senior-mode setup statusline`.

## Report

Summarise the output in plain words, in the project language, with the Project URL
(`gh project view <number> --owner <owner> --web`). On failure, quote the error and the retry command.
