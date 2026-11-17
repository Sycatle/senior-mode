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
   repository, labels, rebase-only merges, a ruleset on the default branch. Proceed on their yes.

## GitHub

Run `senior-mode setup github`. It:

- finds the repository's Project (cached number, else same title) or creates it, links it, ensures the
  fields Status (Backlog, Ready, In progress, In review, Done), Priority (P0 now, P1 next, P2 later,
  P3 someday) and Size (S, M, L), keeping options and values already there;
- caches every id in `.claude/senior-mode.json`, other keys untouched;
- creates or updates the labels `needs-human`, `needs-info`, `blocked`, and on a personal account the
  type labels `type:feature|bug|task|chore` (organizations use issue types);
- allows rebase merges only and deletes branches after merge;
- creates or updates a ruleset `senior-mode` on the default branch: pull requests only, rebase,
  `senior-mode/ci` and `senior-mode/review` on an up-to-date branch, linear history, no force-push or
  deletion; existing protection is left as is; an admin can bypass on purpose with `gh pr merge --admin`.

On a private repository of a free plan GitHub refuses rulesets: it reports it and goes on; the git
hooks and the plugin's guard still apply.

## Report

Show what the command printed as a plain-language summary in the project language (or the user's), with the
Project URL (`gh project view <number> --owner <owner> --web` opens it). On failure, quote the error
and the command to retry; setup is safe to run again.
