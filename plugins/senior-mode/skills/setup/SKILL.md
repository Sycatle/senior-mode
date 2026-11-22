---
name: setup
description: Adopt a repository for senior-mode - GitHub board, labels, merge rules and a ruleset on the default branch - safe to rerun, repairs. Use when the user asks to set up, install or adopt senior-mode in a project, or when a senior-mode command reports a missing config.
disable-model-invocation: true
---

# Setup

Safe to rerun: it repairs. Wording, follow-ups, status line, no human to ask: `${CLAUDE_SKILL_DIR}/reference.md`.

## Before

1. The folder is a git repository with an `origin` remote on GitHub. If not, offer to create one,
   private by default, never without a yes: commit what is there, then
   `gh repo create <name> --private --source . --push`.
2. `gh auth status` succeeds. If the token lacks the `project` scope, ask the user to run
   `gh auth refresh -s project`.
3. Ask once: checks before each push only (`local`, free) or also on GitHub Actions (`actions`,
   spends the budget). Then tell the user, in a short table, what will change: a Project
   board, labels, rebase-only merges, a default-branch ruleset, in `local` the workflows disabled
   (files kept), and the Repository files below. Go on their yes.

## GitHub

Run `senior-mode setup github --ci <local|actions>`. It:

- finds or creates the Project, links it, ensures the fields Status, Priority, Size and Severity, keeping
  existing options;
- creates the labels `needs-human`, `needs-info`, `blocked`, `security` (and `type:*` on a personal account);
- allows rebase merges only, deletes merged branches;
- creates or updates a ruleset `senior-mode` on the default branch: pull requests only, rebase,
  `senior-mode/ci` and `senior-mode/review` required, linear history; other rules kept. If it
  prints `protection: NOT enforced`, see "No branch protection" in the reference;
- `local`: disables the repository's workflows (files kept); `actions`: `setup repo` then adds
  `.github/workflows/senior-mode.yml`. If it prints `releases:`, relay it (the release PR needs
  a `RELEASE_PLEASE_TOKEN` secret to get CI).

## Repository

Set the language (reference), then run `senior-mode setup repo`. With a `package.json` it takes the
`node` preset; otherwise ask once how to lint, typecheck, test and build, and rerun with one
`--command lint="<cmd>"` per answer. It adds checks, hooks, `CLAUDE.md` Principles, templates, permissions,
release-please; what exists is kept. Then the reference's follow-ups.

## Report

Summarise the output in plain words, in the project language, with the Project URL
(`gh project view <number> --owner <owner> --web`). On failure, quote the error and the retry command.
