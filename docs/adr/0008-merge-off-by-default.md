---
id: 0008
title: Autonomous runs stop at reviewed pull requests unless merging is turned on
status: accepted
spec: 0001
supersedes: 0003 (in part: the merge is now opt-in)
---

## Context

ADR 0003 made `run` merge its own pull requests within mechanical bounds. The first real adopters
work in regulated settings or on tools that colleagues use every day: they want every change that
reaches the default branch to have been read by a person, and they want to understand it. Many of
them are also on GitHub Free with private repositories, where the server enforces no branch
protection (the `setup` fallback records `github.protection: "none"`), so the required-status
argument of ADR 0003 does not hold there.

## Decision

- `autonomy.merge` (default `false`) decides whether `run` merges. Off: `run` delivers each ticket up
  to a pull request with `senior-mode/ci` and `senior-mode/review` set, and the final report lists
  what waits for a human.
- On: `run` merges with `gh pr merge --rebase` only when both statuses are `success` on the head
  commit, the pull request has no `needs-human` label, the server enforces protection
  (`github.protection` is `"ruleset"`), and `run` itself finds no protected zone of the default
  branch among the changed files: a model's label is not the only barrier. The merge names the
  checked head (`--match-head-commit`). The ticket session never merges (Bash guard). Every bound of
  ADR 0003 still applies.
- The key replaces `autonomy.autoMerge`, which nothing read yet.

## Alternatives considered

- **Keep merging on by default:** fastest, but the first thing a careful adopter has to do is turn it
  off, and on GitHub Free nothing on the server backs it.
- **Merge S tickets only:** a size is an estimate, not a risk measure.

## Consequences

- By default a person merges, so `review` must give them a plain-language brief of each change.
- Turning merging on is one line of config, recorded in the repository, visible in review.
- ADR 0003 stays the rule for what may be merged; this ADR only decides whether `run` does it.

## Note (2026-11-24, #523)

Amended by [0032](0032-local-protection-on-github-free.md): "the server enforces protection" also holds when `github.protection` is
`local`, where senior-mode requires the three statuses and an up-to-date branch itself and an audit reports direct pushes.
