---
id: 0011
title: A command or skill is merged only after a real session exercised it
status: accepted
spec: 0001
---

## Context

`senior-mode check` validates structure, sizes, scripts and commit subjects. It cannot tell whether a
skill triggers, whether an agent follows it, or whether a hook blocks the right command. Branches that
pass `check` can still fail in use.

## Decision

A command or skill is merged only after a real `claude -p` session exercised it on the sandbox
repository, `Sycatle/senior-mode-sandbox`: private, on GitHub Free on purpose, so the fallbacks of a
free account are the ones tested. The PR body records what was run (command, prompt) and what was seen
(outcome, artefacts). Unverified means not merged.

Hooks follow the same rule: a hook change is exercised in a session where it must allow and deny.

## Alternatives considered

- **`check` alone:** cheap and deterministic, but blind to behaviour.
- **Evals only (v1.0):** costly, run on release PRs; they complement the gate and do not replace it
  before they exist.

## Consequences

- Each behavioural PR costs one short real session; the sandbox keeps it cheap and isolated.
- The PR evidence is reviewed with the diff; a PR without it is not ready.
