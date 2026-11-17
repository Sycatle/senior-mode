---
id: 0006
title: Checks run locally and publish commit statuses; hosted CI is optional
status: accepted
spec: 0001
---

## Context

Bounded autonomy (ADR 0003) relies on required checks. Many target users have no GitHub Actions
budget (minutes used up, account locked for billing, private repositories), and senior-mode itself is
built without it. Blocking hooks alone leave no proof on the PR and do not stop a merge from the web.

## Decision

- Each project has one check list (lint, typecheck, tests, build, Conventional Commits, spec drift,
  secret scan) defined by its preset and stored in `.claude/senior-mode.json`.
- `senior-mode check` runs it locally on the PR head (pre-push hook, and before every merge in `run`)
  and publishes the commit status `senior-mode/ci` through the GitHub API, with a summary of what ran.
- Branch protection requires `senior-mode/ci` and `senior-mode/review`, whoever produced them.
- `ci.mode` is `local` by default; `actions` also emits the same check list as a GitHub Actions
  workflow. Workflows already in a repository are disabled, not deleted, when the mode is `local`.
- Releases: `senior-mode release` runs the release-please CLI locally after merges to the default
  branch; in `actions` mode the official action does it.
- Scheduled runs use a local scheduler (cron, systemd timer, launchd) running `claude -p`, or a cloud
  scheduled task, or Actions in `actions` mode.

## Alternatives considered

- **Local hooks only:** simplest, but nothing visible on the PR and nothing enforced on the server.
- **Self-hosted runner:** keeps Actions, but needs a machine always on and can be blocked by the same
  billing lock.

## Consequences

- A status published from a developer machine is only as trustworthy as that machine: it states the
  commit it verified, and `run` re-checks before merging. Teams that need independent CI use
  `actions` mode.
- The check list is written once and reused by both modes, so switching mode costs nothing.
