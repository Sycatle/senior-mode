---
id: 0003
title: Autonomous runs merge by themselves within mechanical bounds
status: accepted
spec: 0001
---

## Context

The point of `run` is to advance the roadmap without the user. Stopping at an open PR keeps a human in
every loop; merging without limits lets one bad ticket cascade.

## Decision

`run` merges its own PRs (rebase, auto-merge once required checks pass) when all hold:
- the ticket was Ready (Definition of Ready) and is size S or M;
- CI and the `senior-mode/review` status from a fresh-context Opus reviewer are green;
- no file in a protected zone is touched: data migrations; security, auth, permissions, secrets,
  payments; CI, infrastructure, container files, major dependency upgrades; any L ticket or ADR.
  Those PRs get `needs-human` and wait.

A run handles at most N tickets (default 3) and stops after 2 consecutive failures or when a ticket
outgrows its size. During a run, hooks deny edits to CI, hooks, config and the protected-zone list.

## Alternatives considered

- **Open PRs, human merges:** safest, but the user remains the bottleneck the plugin is meant to remove.
- **Auto-merge S tickets only:** safer, but most valuable work is M.
- **Token or time budgets:** more precise in theory, but depend on what the harness exposes; ticket
  counts are predictable and explainable to non-developers.

## Consequences

- Safety rests on CI quality: `setup` must install real checks before `run` is allowed
  (`run` refuses without branch protection and required checks).
- The reviewer status is a required check, so agents cannot merge around it.
