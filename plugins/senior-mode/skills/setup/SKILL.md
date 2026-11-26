---
name: setup
description: Adopt a repository for senior-mode - GitHub board, labels, merge rules and a ruleset on the default branch - safe to rerun, repairs. Use when the user asks to set up, install or adopt senior-mode in a project, or when a senior-mode command reports a missing config.
disable-model-invocation: true
---

# Setup

Wording, follow-ups, status line, no human to ask: `${CLAUDE_SKILL_DIR}/reference.md`.

## Before

1. The folder is a git repository with an `origin` remote on GitHub. If not, offer to create one,
   private by default, never without a yes: commit what is there, then
   `gh repo create <name> --private --source . --push`.
2. `gh auth status` succeeds. If the token lacks the `project` scope, ask the user to run
   `gh auth refresh -s project`.
3. Run `senior-mode setup detect`, then ask the three questions of the reference ("Questions") in one round.
   Run `senior-mode setup answers --dry-run <flags>` and show its summary (facts, answers, defaults). On their yes,
   rerun it without `--dry-run`: it writes the answers, nothing on GitHub.

## GitHub

Run `senior-mode setup github --ci <local|actions>` (`local` unless asked). It:

- finds the Project or copies the template board, links it, ensures its fields (Iteration, Start, End too): see "Board" in the reference;
- creates the labels `needs-human`, `needs-info`, `blocked`, `security` (and `type:*` on a personal account);
- allows rebase merges only, deletes merged branches;
- creates or updates a ruleset `senior-mode` on the default branch: pull requests only, rebase,
  `senior-mode/ci`, `senior-mode/review` and `senior-mode/security` required, linear history; other rules kept. If it
  prints `protection: NOT enforced`, see "No branch protection" in the reference;
- with `protected` globs, writes the `senior-mode:begin`/`end` block of `.github/CODEOWNERS` (owner's
  entries kept) and requires code owner review. Tell the user to commit the file, and that an owner
  merges their own protected-zone pull request by hand, with `gh pr merge --admin`. `setup repo` writes `protected`, so rerun `setup github` after it;
- turns on the scanners: see "Scanners";
- `local`: disables the repository's workflows (files kept); `actions`: `setup repo` then adds
  `.github/workflows/senior-mode.yml`. If it prints `releases:`, relay it (the release PR needs
  a `RELEASE_PLEASE_TOKEN` secret to get CI). On `built-in workflows off:`, tell the user to turn them on in
  the Project's Workflows tab.

## Repository

Run `senior-mode setup repo`. With a `package.json` it takes the
`node` preset; otherwise ask once how to lint, typecheck, test and build, rerun with one
`--command lint="<cmd>"` per answer. It adds checks, hooks, `CLAUDE.md` Principles, templates, permissions,
release-please; what exists is kept. Legacy: survey first. Then the reference's follow-ups.

## Report

Summarise the output in plain words, in the project language, with the Project URL
(`gh project view <number> --owner <owner> --web`). On failure, quote the error and the retry command.
