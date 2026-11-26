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
- `release.sh`: `release` (release-please).
- `check.sh`: `check`, spec drift, `security_verdict`, `publish`.
- `guard.sh`: `secret_scan`, `audit`, `e2e_lock`, slots, `protected`, `red_tests`.
- `setup-board.sh`: Project creation, migration, fields, cycles, board workflows.
- `setup.sh`: `setup github` (CODEOWNERS, ruleset, labels) and `setup repo` (presets, hooks, CLAUDE.md).
- `packages.sh`: monorepo `packages` (workspaces, Cargo, Go modules) for `setup repo`, and `install_plan` for `start`.
- `setup-workflow.sh`: detection of the project's workflow for `setup repo` (`--dry-run`, `--adopt`).
- `workflow.sh`: reading the detected `workflow` (branch pattern, base, merge flag, PR gaps) for start, run, serve, status, clean.
- `setup-answers.sh`: `setup detect` and `setup answers` (the three questions: detection, profile, config layers).
- `setup-remove.sh`: `setup remove` (files through a pull request, ruleset, labels, workflows).
- `status.sh`: `status`, hygiene, health, `retro`, `statusline`.
- `context.sh`: `context` (the session briefing: selection, ranking and budget of specs, ADRs and notes).
- `repomap.sh`: the repo map of the briefing (symbols and signatures of the ticket's Paths, ctags or regex, index cached by tree sha).
- `retro-learn.sh`: failure causes and improvement tickets of `retro`.
- `retro-notes.sh`: notes to merge or delete and agent memory drafts, the facts of the `retro` knowledge pull request.
- `skeleton.sh`: red test skeletons of `start` and their `ready` check.
- `clean.sh`: `clean` (branches, worktrees).
- `run.sh`: `run` (ticket sessions, review, merge, report) and its helpers.
- `prompts.sh`: prompts of the run and serve sessions.
- `schedule.sh`: `schedule install` (cron, systemd).
- `serve.sh`: `serve` (poll loop, requalify, rebase, merge, digest).
- `watchdog.sh`: serve's watchdog (hung sessions, orphan processes, stale `index.lock`).

## Pitfalls

- A module cannot rely on `BASH_SOURCE`: use `$SELF` (the entry's real path) and `$LIB`.
- A new module needs a `# shellcheck source=lib/<name>.sh` line and its `.` line in the entry point.
- Usage line: exactly one `die "usage: senior-mode ..."`, in the entry; `docs-drift.sh` reads it.
