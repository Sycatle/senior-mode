---
id: 130
title: Agents cannot ship a known vulnerability, leak a secret or loosen their own guards
status: accepted
size: L
paths: ["plugins/senior-mode/bin/senior-mode", "plugins/senior-mode/hooks/**", "plugins/senior-mode/agents/**", "plugins/senior-mode/skills/review/**", "plugins/senior-mode/skills/setup/**", "plugins/senior-mode/presets/**", "plugins/senior-mode/templates/**"]
adrs: ["0015"]
issue: "#130"
---

# Agents cannot ship a known vulnerability, leak a secret or loosen their own guards

## Problem

senior-mode lets agents with a shell work unattended on a VPS (ADR 0003, 0008). Today the security
of what they produce rests on one line of the `review` skill. Spec 0001 §14 says every preset checks
for secrets, but no check does. Nothing audits dependencies. Nobody watches CVEs published after a
merge. The review of #113 found seven ways a session can stall a run, loosen its own guards or slip
past the work-in-progress limit (#115-#121, #145). A human who only frames must be able to trust
that a merged change was checked for security, and that what could not be checked waits for them.

## Users and journeys

- **The owner** frames and reads the board. A security risk reaches them as a triaged issue with a
  severity, or as a pull request held by a red `senior-mode/security`. Never as a surprise in
  production.
- **A ticket agent** works under hooks it cannot turn off. Before every push its diff is scanned
  for secrets and its dependencies audited. A risk it sees outside its ticket becomes an issue, not
  a silent fix.
- **The `security` agent** (Opus) reviews L tickets and changes to protected zones and sets its own
  required status.

## Acceptance criteria

Posture (#139):

- ADR 0015 records the threat model, what blocks, what alerts and what stays human; it is
  `accepted` with this spec.

Review, two levels (#140, #141):

- Given any pull request, when `review` runs, then its Security section is applied: injection,
  authorization, secrets, unsafe shell, supply chain, data exposure. Each finding gives a file, a
  line and a fix. A high or critical finding blocks: `senior-mode/review` is not set to success.
- Given a pull request that touches a protected zone (`senior-mode protected` exits 0) or closes an
  L ticket, when the `security` agent (Opus) has reviewed it with no high or critical finding,
  then it sets `senior-mode/security` to success. Otherwise the status stays pending, or fails with
  the findings, and the pull request gets `needs-human`.
- Given any other pull request, when `publish` runs, then it sets `senior-mode/security` to success
  with the description "not required: no protected zone, not L". `setup github` adds
  `senior-mode/security` to the ruleset's required checks.
- Given `run_merge` (and the `next` skill's merge), then it merges only when `senior-mode/ci`,
  `senior-mode/review` and `senior-mode/security` are all success on the head commit. ADR 0015
  amends ADR 0008 on this point.

Local checks before push (#142, #143):

- Given a preset with a lockfile (npm or pnpm, pip, go, cargo), when `check` runs, then the
  ecosystem's audit runs and fails on a high or critical advisory, naming the package, the
  advisory and the fixed version. When the tool gives no severity for an advisory (often pip-audit,
  govulncheck, cargo audit), the check passes and prints it as a warning; Dependabot is the net
  for those.
- Given the audit tool is missing, then the check fails and says how to install it. `audit: false`
  in the config turns the check off, and `status` shows it as off.
- Given a diff `<base>...HEAD` that adds a line matching a secret pattern shipped in the plugin,
  when `check` runs, then it fails with the file, the line and the kind of secret. It never prints
  the value.
- Given a value whose sha256 is in `.claude/secret-allowlist` with a reason, as read from the base
  branch (`git show <base>:.claude/secret-allowlist`), then the check passes. A pull request cannot
  allowlist its own secret. `setup` adds the file to `protected`, and self-protect denies run
  sessions writes to it.
- Spec 0001 §14 is corrected so it no longer claims secret scanning exists before this work.

GitHub native (#171, #172):

- Given `protected` globs, when `setup github` runs, then `.github/CODEOWNERS` maps each one to the
  owner and the ruleset requires code owner review. A rerun keeps the entries added by hand.
- Given a plan that allows it, when `setup github` runs, then Dependabot alerts, Dependabot
  security updates (grouped, high and critical only, no version updates), secret scanning and push
  protection are on. When the plan refuses, setup says so and continues.
- Given a high or critical Dependabot or secret-scanning alert open on the repository, when `run`
  starts or `retro` runs, then exactly one open triaged issue exists for it, through the same path
  as #144; a second pass files nothing new.

Triage of risks (#144, Severity):

- `setup github` creates a single-select field Severity (critical, high, moderate, low). `issue
  create --severity` sets it and adds the label `security`.
- Given an agent finds a risk outside its ticket, then it files an issue with `--severity`, and the
  body carries no exploit detail. It is deduplicated by a fingerprint in the body (`security-id:
  <sha256 of kind, path and rule>`) against open issues.
- Critical is P0 and is first in `pick`. High is P1.
- A critical finding in a public repository also opens a private security advisory, which holds
  the details.

Guard hardening (#115-#120, #145):

- #115: Given a session runs longer than `autonomy.sessionTimeout` (default 90 minutes), then `run`
  kills it, labels the ticket `needs-human` with the log path, and counts it as a failure for the
  breaker. A timeout is not retried on a stronger model (ADR 0014 escalates failed work, not stuck
  sessions).
- #116 (with #121): `guard-bash` denies, in any session, setting or unsetting `core.hooksPath`
  through `git config`, and a `PUT` on the merge endpoint whatever the variables in the path. In a
  run session it also denies `gh api` writes to rulesets and branch protection, and
  `self-protect` denies writes, by Edit, Write or the shell, to the git hooks and `.git/config` of
  the common dir (every worktree included). Denying writes to commit statuses waits for the
  separate reviewer session (#150), which is the only one that may set them. Read-only `gh` calls
  such as `gh pr list --search merge` are allowed. `run_merge` refuses to merge when the base has
  no `.claude/senior-mode.json`.
- #117: Given `run` starts, then it checks that the plugin is enabled and `hooks.json` is present.
  Once a day it also runs a probe session that tries a denied, harmless command. If the deny does
  not show, `run` refuses to start.
- #118: Given `crontab -l` fails for a reason other than "no crontab", then `schedule install` and
  `schedule remove` stop and change nothing.
- #119: The e2e lock lives in `$XDG_RUNTIME_DIR`, else in a private 0700 directory, never in a
  shared `/tmp` path.
- #120: The `run_docs` session after merges is bounded by the same timeout and recorded in the run
  log.
- #145: `run` writes a random token to a 0600 file and passes its path to `start`. `start` skips
  `wip` only when the token matches. `SENIOR_MODE_RUN=1` set by hand no longer does.

## Design

- **Statuses.** `senior-mode/ci` and `senior-mode/review` keep their meaning. `senior-mode/security`
  is the third required context. The `security` agent sets it, or `publish` sets it when the pull
  request is not concerned. Whether the pass is due is mechanical (`protected`, the ticket's Size),
  so `publish` never marks a due pass as not required. A ticket session could still post the status
  itself through `gh api` until the separate reviewer session (#150) is the only one allowed to.
- **Secret patterns** ship in `plugins/senior-mode/secret-patterns` (provider keys, credentialed
  URLs, private keys, generic assignments). There is no new dependency, so the generic kind is a
  heuristic, not an entropy measure: a value of 16 characters or more, with a letter and a digit, that
  is not a placeholder, a bracketed expression or a dotted identifier. The secret an allowlist entry
  hashes is the value itself: the token, the whole URL, or a private key from its `BEGIN` to its `END`
  line, never the public header alone.
- **Audit commands** live in each preset's checks: `npm audit --audit-level=high` or `pnpm audit
  --audit-level high`, `pip-audit`, `govulncheck ./...` and `cargo audit`. The JSON output is
  filtered to high and critical.
- **Issues** go through `issue create`. The fingerprint is searched as a quoted phrase in the body
  (`gh issue list --state open --search '"security-id <id>" in:body'`), so it does not read as a
  search qualifier.
- Every decision is in ADR 0015.

## Rollout and risks

- Slice order: ADR, then the guard bugs (they are known holes), then Severity, the review section,
  the local checks, the native features, the `security` agent, and triage.
- Making `senior-mode/security` required blocks every open pull request until `publish` reruns, so
  `setup github` adds it last and says so.
- Agents keep the owner's identity (#175). CODEOWNERS and statuses block the normal path, and the
  guards deny the bypasses they know (`--admin`, rulesets, the merge endpoint). A determined session outside the hooks
  can still bypass them. #117 narrows that gap, and #175 closes it.
- False positives in the secret scan cost a human an allowlist entry, by design.

## Out of scope

- A separate agent identity (#175).
- Dynamic testing (DAST), fuzzing, container image scanning.
- Version-update pull requests from Dependabot.

## Test seams

`check` with fixture diffs and stubbed audit tools (`test-check.sh`, a new `test-secret-scan.sh`).
`publish` and `setup github` with the gh stub (`test-setup-github.sh`). `issue create --severity`
and `pick` (`test-issue.sh`). `run`, `run_start`, `run_merge`, `start`, `schedule` and the e2e lock
(`test-run.sh`, `test-start.sh`, `test-schedule.sh`, `test-e2e-lock.sh`). `guard-bash.sh` and `self-protect.sh` (`hooks/tests/`). The `review` skill and the
`security` agent for the steps a model performs.

## Open questions

None.
