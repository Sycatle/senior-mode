---
id: 0032
title: On GitHub Free the merge gate moves to senior-mode, with an audit of direct pushes
status: accepted
amends: 0008, 0018
---

## Context

ADR 0008 and ADR 0018 let `run` and `serve` merge only when the server enforces protection
(`github.protection` is `ruleset`). GitHub refuses rulesets and branch protection on a private repository of a Free
account or organization, so there `run_blocker` refused every merge and `serve` stopped at each pull request. The owner
decided on 2026-11-24 (#523) that senior-mode must not require a paid GitHub plan.

## Decision (owner, 2026-11-24)

- **A new value, `github.protection: "local"`.** `setup github` records it, in place of `"none"`, when GitHub refuses the
  ruleset (HTTP 403 on a private Free repository), and keeps `ci.mode: local`. `"none"` stays readable as before (no merge
  on its own), so a repository can opt out by writing it.
- **`run_blocker` accepts `ruleset` or `local`.** Under `local` it emulates what the ruleset required: the three statuses
  `senior-mode/ci`, `senior-mode/review` and `senior-mode/security` must be `success` on the head whatever
  `github.requiredChecks` says (a profile that lifts the review still drops that one), and the branch must be up to date
  with the base (`compare` base...head, `behind_by` is 0). A branch that is behind gets the reason "it is behind", and
  `serve`'s rebase step updates it as it does for GitHub's `behind` state. Every other bound is unchanged: merging on, not
  external, no `needs-human`, no protected zone, a delivery that is ready.
- **The Bash guard is unchanged:** it already denies a session any push to the default branch.
- **An audit of direct pushes.** Under `local`, `setup github` writes `.github/workflows/senior-mode-audit.yml` for the
  project to commit. On each push to the default branch, for every pushed commit it asks `GET /repos/{r}/commits/{sha}/pulls`;
  a commit that belongs to no merged pull request into that branch opens one issue labelled `needs-human`, "Direct push to
  <branch> outside a pull request", or comments on the one already open, with the commits and the pusher. It has the
  permissions `contents: read`, `issues: write` and `pull-requests: read`, uses no action and no secret, and the workflow
  is not disabled by `ci.mode local`.
- **Said plainly, in the setup output and the docs:** local protection is not server protection. Anyone with push access
  can still push to the default branch, and the audit only reports it.

## Alternatives considered

- **Keep refusing to merge on Free:** the daemon is useless on the plan most solo users have.
- **Merge without any check of the statuses:** nothing would stand in for the ruleset.
- **Fail the push from a workflow:** a workflow runs after the push and cannot refuse it.

## Consequences

- ADR 0008 and ADR 0018 now read "the server enforces protection, or senior-mode does (`local`)".
- A pull request cannot be refused by GitHub on Free: the merge command, not the server, holds the gate, so a person
  who merges by hand, or pushes, is outside it and found only by the audit.
- A later run of `setup github` on a plan that allows rulesets creates the ruleset and records `"ruleset"`; the audit
  workflow stays, and finds nothing to report.
