# Surface audit: commands, skills and config keys (#318)

Audited on 2026-11-23, on `main` after #302. Every command, skill, agent and config key the plugin ships,
with the evidence that something uses it, and a verdict:

- **keep**: a person uses it, as it is.
- **merge**: it goes into another surface; the ticket says where.
- **hide**: callers are agents, hooks or `check`; it stays, out of the human's view.
- **remove**: nothing uses it.

Evidence is counted in the repository:
- **tests**: `bin/tests` and `hooks/tests` that call it;
- **callers**: the skills, agents, hooks and lib code that call it;
- **guide**: `docs/guide`.

Real use is this repository's own: its sessions, the `serve` trial and the release runs (#475).

**Result.** Nothing is dead: every surface has a caller and a test, so this pull request removes no code.
The human-facing surface is too wide, and the work is to hide the rest:
- #319 hides the internal surface and merges `next` and `run` into `/go`;
- #509 decides whether `schedule` folds into `serve`.

## Commands of `bin/senior-mode`

| Command | Tests | Callers | Verdict |
|---|---|---|---|
| `setup github \| repo \| statusline` | 9 files | `setup` skill, board, release | keep: run once per repository, through `/senior-mode:setup` (in #320, through the first `/go`) |
| `status` | test-status | `status` skill, `check`, `serve` | keep: one of the three human verbs (#319) |
| `run` | test-run, test-schedule | `run` skill, `schedule`, guard-bash | merge: into `/go`, when the config asks for a batch (#319) |
| `serve [--install\|--uninstall\|--resume]` | test-serve | `serve --install` unit, prompts | merge: `/go` starts or attaches to it (#319) |
| `schedule install\|remove\|status` | test-schedule | `run` skill | keep for now; whether it folds into `serve` is #509 |
| `retro` | test-retro | `retro` skill | keep, not advertised: the weekly retro is proposed by `/status` and `serve` (#319) |
| `check [--pre-push]` | 8 files | pre-push hook, implementer, security, serve, proof hook | hide: the hook and the agents run it |
| `publish [commit]` | test-check | pre-push hook, serve | hide |
| `release [--dry-run]` | test-release | `ops` agent | hide: the ops agent and the release flow run it |
| `pick`, `start` | test-start, test-issue | `next` skill, `run` | hide: steps of `/go` |
| `clean` | test-clean | `run`, `serve`, `status --fix` | hide: runs at the start and end of each run |
| `statusline` | test-statusline | the project's status line | hide: Claude Code calls it |
| `frame start\|end` | test-frame-guard, test-issue | `frame` skill, frame-guard hook | hide: the skill drives it |
| `issue create` | test-issue, test-run | 6 skills and agents, prompts | hide |
| `item set\|get` | test-issue | ops, security, setup, prompts | hide |
| `config get` | 7 files | 6 skills and agents | hide |
| `protected` | test-protected | reviewer, security, prompts | hide |
| `ready` | test-ready | `serve`, board | hide: `serve` runs it each poll |
| `red-tests record` | test-red-tests | test-author flow, guard | hide |
| `slot -- <cmd>` | test-slot | every session `run` and `serve` start | hide |
| `e2e-lock -- <cmd>` | test-e2e-lock | `check` (the `e2e` check) | hide |
| `context` | test-context | the SessionStart hook | hide |
| `secret-scan`, `audit`, `deps` | test-secret-scan, test-audit, test-deps | `check` steps | hide (already out of the guide's table) |

## Skills

The human types `/senior-mode:<name>` for the skills with `disable-model-invocation: true`. Claude loads
the others when their description matches, or another skill or agent calls them.

| Skill | Invoked by | Callers | Verdict |
|---|---|---|---|
| `frame` | human | guide, frame-guard hook, tests | keep: a human verb (#319) |
| `status` | human | guide | keep: a human verb (#319) |
| `next` | human | guide | merge: into `/go` (#319) |
| `run` | human | guide, autonomy guide | merge: into `/go` (#319) |
| `setup` | human | guide, board, check, setup code | hide behind the first `/go` (#319, #320); still callable |
| `retro` | human | guide | hide: proposed by `/status` once a week (#319); still callable |
| `grill` | model | `frame`, frame-guard tests | keep, internal |
| `spec`, `adr` | model | `frame`, architect | keep, internal |
| `ready` | model | autonomy guide, `serve` | keep, internal |
| `triage` | model | session start context | keep, internal |
| `tdd`, `verify`, `commit` | model | implementer, proof hook, frame-guard tests | keep, internal |
| `review` | model | reviewer agent, configuration guide | keep, internal |
| `docs` | model | `run` docs session, setup | keep, internal |

## Agents

Every agent has a caller. `implementer`, `reviewer`, `security` and `test-author` are started by the
daemon's prompts. `ops`, `scout`, `architect` and `researcher` are started by skills (`setup`, `status`,
`frame`). Verdict: keep all eight. They are never a human surface.

## Config keys (`.claude/senior-mode.json`)

All keys of `DEFAULTS` (`bin/lib/common.sh`) and those setup writes have a reader and a test. None is
removed.

| Keys | Read by | Verdict |
|---|---|---|
| `language` | skills, agents, setup | keep: a setup question (#320) |
| `checks`, `commands` | `check`, guards, proof hook | keep: setup detects them |
| `preset` | `check`, setup | hide: setup writes it |
| `project.*`, `github.protection`, `board.template` | board, guards, setup | hide: setup writes them, not for hand edits |
| `ci.mode` | 35 test files, guards, board | keep |
| `protected`, `secrets`, `envGuard.forbidden` | guards, reviewer, setup | keep: safety levers that only add (ADR 0027) |
| `audit`, `security.minPackageAgeDays`, `security.minWeeklyDownloads` | `check` | keep |
| `autonomy.*` (maxTickets, parallel, maxConsecutiveFailures, merge, escalate, sessionTimeout, schedule, ticketsPerHour, sessionsPerHour, minMemoryMB, userSettings) | `run`, `serve`, `schedule` | keep; `autonomy.merge` maps to the "may agents work alone" question (#320) |
| `serve.interval`, `serve.grace`, `serve.breakerCooldown` | `serve` | keep |
| `notify.mention`, `notify.webhook`, `notify.digest` | `serve`, `run` | keep |
| `agent.command` | `run`, `serve`, probe | keep |
| `e2e.slots`, `slot` | `e2e-lock`, `slot` | keep |
| `limits.prLines`, `wip` | `check`, `start` | keep |
| `hygiene.days` | `clean`, `status` | keep |
| `board.archiveAfterDays`, `board.iterationDays` | `run`, setup | keep |
| `review.sections`, `docs.extra` | `review` and `docs` skills | keep |

Layers and profiles for these keys are #307 and #320. This audit does not change the keys themselves.
