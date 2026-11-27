# senior-mode

## Commands

- Verify everything: `plugins/senior-mode/bin/senior-mode check` (manifests, shellcheck, docs drift, tests).
- One test file: `plugins/senior-mode/bin/tests/test-<name>.sh`; hooks: `plugins/senior-mode/hooks/tests/`.
- shellcheck: `.github/scripts/shellcheck.sh` (follows the sources of the CLI with `-x`).

## CLI module map

`plugins/senior-mode/bin/senior-mode` is the entry point: `usage`, the `source` lines and the command
dispatch (`case`). Everything else lives in `plugins/senior-mode/bin/lib/<domain>.sh`. A module holds
definitions only (functions, constants): top-level statements stay in the entry point. The entry
resolves `lib/` from its own real path (`readlink -f`), so it works through a symlink and the plugin cache.

- `common.sh`: defaults, `die`, config (`config_get`), `gh_retry`, small shared helpers.
- `config.sh`: the schema walker, `config validate`, the layers, `config_get`, `config explain`, overrides and process
  profiles (schema in `plugins/senior-mode/schema/`, shipped profiles in `plugins/senior-mode/profiles/`).
- `doctor.sh`: `doctor` (installation checks, fixes, customization summary).
- `state.sh`: `state_write` (tmp + `mv`), `state_update` (flock), `state_get`/`state_num`/`state_json` (tolerant readers).
  Every write under the serve dir goes through it (`.github/scripts/state-writes.sh` checks `run.sh` and `serve.sh`).
- `board.sh`: Project items and fields, `issue create`, security alerts, `ready`, `pick`, `start`.
- `architecture.sh`: `architecture` (the generated map and its block in `docs/architecture.md`).
- `ratchet.sh`: `ratchet` (the lint and coverage baseline of legacy code, `ratchet-check` step of `check`, `check --update-baseline`).
- `release.sh`: `release` (release-please).
- `check.sh`: `check`, spec drift, `security_verdict`, `publish`.
- `characterize.sh`: `untested` (files with no tests that need a characterization commit, `--check`), the pinned-edit gate of `ready`.
- `evals.sh`: the skill eval gate of `ready` (an improvement pull request on a skill or agent needs its before/after table).
- `guard.sh`: `secret_scan`, `audit`, `e2e_lock`, slots, `protected`, `red_tests`.
- `setup-board.sh`: Project creation, migration, fields, cycles, board workflows.
- `setup.sh`: `setup github` (CODEOWNERS, ruleset, labels) and `setup repo` (presets, hooks, CLAUDE.md).
- `packages.sh`: monorepo `packages` (workspaces, Cargo, Go modules) for `setup repo`, and `install_plan` for `start`.
- `setup-knowledge.sh`: `setup repo --knowledge` (migration to the long-lived project layout: ADR paths, notes from agent drafts, vision draft,
  baseline, labels, maintenance epic, orphans).
- `survey.sh`: `survey` (measures as JSON) and the architecture survey of `setup repo --adopt` on a legacy project (drafts in `.claude/survey/`).
- `debt.sh`: debt tickets (`setup repo --adopt --debt`, serve's `debt_poll`): baselines and dormant zones into ranked gardening tickets.
- `setup-workflow.sh`: detection of the project's workflow for `setup repo` (`--dry-run`, `--adopt`).
- `workflow.sh`: reading the detected `workflow` (branch pattern, base, merge flag, PR gaps) for start, run, serve, status, clean.
- `setup-answers.sh`: `setup detect` and `setup answers` (the three questions: detection, profile, config layers).
- `setup-remove.sh`: `setup remove` (files through a pull request, ruleset, labels, workflows).
- `org.sh`: the organization layer's file and `setup org` (the organization's template Project, its pull request on `<owner>/.github`, `--print-ruleset`).
- `status.sh`: `status` (board drift, decisions, dashboard, hierarchy, `--fix`, local facts, the command).
- `status.d/<name>.sh`: the status sections (one per feature: a JSON part, its order, its text), sourced by a glob; the recipe is at the top of `status.sh`.
- `status-hygiene.sh`: the repository hygiene (stale pull requests, branches, superseded, orphans) and its `--fix` repairs.
- `status-board.sh`: cycle (iteration) fields, board archive, Project status updates, health of the Project.
- `retro.sh`: `retro` (facts of the period: history, runs, usage, checks, calibration, iteration).
- `statusline.sh`: `statusline` and `setup statusline`.
- `context.sh`: `context` (the session briefing: selection, ranking and budget of specs, ADRs and notes).
- `checkpoint.sh`: `checkpoint` (the `senior-mode:checkpoint` block of the ticket's draft pull request; read back by `context` and by the plan guard of `run`).
- `repomap.sh`: the repo map of the briefing (symbols and signatures of the ticket's Paths, ctags or regex, index cached by tree sha).
- `retro-learn.sh`: failure causes and improvement tickets of `retro`.
- `retro-notes.sh`: notes to merge or delete and agent memory drafts, the facts of the `retro` knowledge pull request.
- `retro-proof.sh`: the run proof of `retro` (merge gate audit, metrics of the period) and `serve`'s hourly snapshot (`snapshots.jsonl`).
- `skeleton.sh`: red test skeletons of `start` and their `ready` check.
- `clean.sh`: `clean` (branches, worktrees).
- `run.sh`: `run` (ticket sessions, review, merge, report) and its helpers.
- `prompts.sh`: prompts of the run and serve sessions.
- `schedule.sh`: `schedule install` (cron, systemd).
- `egress.sh`: the egress allowlist of sandboxed sessions (`egress_decide`, `egress_start`/`egress_stop`); the proxy itself is `plugins/senior-mode/sandbox/egress-proxy.sh` (socat, one handler per connection).
- `sandbox.sh`: `sandbox_mode`, `sandbox_runtime` (podman, then docker), `sandbox_enabled`, `sandbox_credential_ok` and the pure
  `sandbox_decide` (container, host or hold).
- `serve.sh`: `serve` (poll loop, requalify, rebase, merge, digest).
- `demo.sh`: `demo` (a throwaway repository with three toy tickets, delivered by serve; progress in `demo.json`).
- `broker.sh`: `broker_allow` (the credential broker's decision: which gh, git push and senior-mode verbs a sandboxed session may run).
- `additive.sh`: the additive merge of the shared root files of `serve.sharedPaths` (package.json, Markdown; a lockfile is regenerated).
- `dependabot.sh`: `dependabot_assess` (a Dependabot pull request: ready, wait until a release age, or human).
- `watchdog.sh`: serve's watchdog (hung sessions, orphan processes, stale `index.lock`).

## Pitfalls

- A module cannot rely on `BASH_SOURCE`: use `$SELF` (the entry's real path) and `$LIB`.
- A new module needs a `# shellcheck source=lib/<name>.sh` line and its `.` line in the entry point (not a status section).
- A new line or key of `status` is a section file, not an edit of `STATUS_JQ` or `STATUS_TEXT_CORE`.
- Usage line: exactly one `die "usage: senior-mode ..."`, in the entry; `docs-drift.sh` reads it.
