---
name: verify
description: Prove a change works by running the project's checks and reading their output before claiming success. Use before saying a task is done, before pushing, before opening or merging a pull request.
---

# Proof before claims

"Done" is a statement about evidence. Without fresh output from the checks, nothing is done.

## Run

- `senior-mode check` runs the project's check list from `.claude/senior-mode.json` (lint, types,
  tests, build, commit messages, spec drift) and records the result for the commit on a clean tree.
- After pushing, `senior-mode publish` sends that result to the pull request as `senior-mode/ci`.
- When behaviour can be exercised (a CLI, a server, a page), exercise it too and say how.
- Re-run after every change; a result from before the last edit proves nothing.

## Read

- Read the output, not only the exit code: skipped tests, warnings promoted later, a test suite that
  ran zero tests.
- Filter long output to the failures before reasoning about it.

## Report

- Say exactly what ran and what it showed. Quote the relevant failing lines.
- Never claim a check passed when it did not run; say it was not run and why.
- Never weaken a check to get green: no skipped tests, no lowered thresholds, no disabled lint rules,
  no `--no-verify`. Fix the cause, or stop and report.
- A check that cannot run here (missing tool, no network) is reported as not verified, with the
  command to run it.
