---
id: 0016
title: How this repository delivers its own backlog: no review, one dogfood session per release
status: accepted
spec: 0001
supersedes: 0011 (in part: the real session runs per batch, before each release, not per pull request)
---

## Context

ADR 0011 asks for one real `claude -p` session on the sandbox repository per behavioural pull request,
and ADR 0015 and the contributing guide ask for an independent review of each one. On this repository,
which has a single owner and a fast backlog, that cost more than it protected: the sessions queued up
and most defects were found by the batch run anyway. The plugin's defaults for the projects that adopt
it do not change; only how senior-mode delivers its own backlog does.

## Decision

For this repository only:

- **Dogfooding per batch.** The real `claude -p` session on `Sycatle/senior-mode-sandbox` runs once
  per batch of merged tickets, before each milestone release, not per pull request. A change is
  unverified until that session has run; the release waits for it.
- **No independent review.** A pull request merges once `senior-mode check` is green. A verification
  pass (review of the batch and the dogfood session) runs before each release.
- **No required status check.** The ruleset requires a pull request, linear history, no force-push
  and no deletion. It requires no `senior-mode/*` status for now.
- **Several tickets per pull request.** A pull request may close several tickets of one theme: one
  commit and one `Closes #n` each.
- **Minimal ceremony.** `check` green and `Closes #n`. Tests when behaviour changes. No red run and no
  `Spec-Unchanged` line required here.
- **The bash guard is best-effort.** Only a trivial bypass or a false positive that hurts the flow
  becomes a ticket; the others go to the known limits in `docs/guide/autonomy.md`.

Protected zones still need a maintainer's approval (ADR 0015).

## Alternatives considered

- **Keep ADR 0011 per pull request:** the strongest evidence, but it serialises the whole backlog on
  a session per ticket.
- **Drop the dogfooding gate:** fastest, but `check` is blind to behaviour; the release pass keeps it.

## Consequences

- A defect can sit on `main` until the release pass; the pass is the net, and it files what it finds.
- Behaviour that matters to users of the plugin is still exercised for real before it is released.
- Contributors to this repository follow `CONTRIBUTING.md`; projects that adopt senior-mode keep the
  defaults of ADR 0011 and 0015.
