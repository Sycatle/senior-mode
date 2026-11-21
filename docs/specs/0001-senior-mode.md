---
id: 0001
title: senior-mode, a Claude Code plugin for senior-grade delivery
status: accepted
size: L
paths: ["plugins/**", ".claude-plugin/**", "evals/**"]
adrs: [0001, 0002, 0003, 0004, 0005, 0006, 0009, 0010, 0011, 0012, 0013, 0014]
---

# senior-mode

## 1. Problem

People who build software with AI agents, technical or not, ship fast and then drown: no backlog, no
priorities, no tests, giant unreviewable diffs, docs that rot, decisions nobody remembers. Existing
workflow kits each solve a slice:

| Reference | Keeps | Misses |
|---|---|---|
| superpowers | proof before "done", fresh context per task, model escalation, worktrees | ~160 KB of skills injected every session, process imposed on every task, no GitHub integration |
| mattpocock/skills | small composable skills, grilling interviews, vertical-slice tickets, two-axis review | no model routing, no Projects, no CI, no autonomy |
| spec-kit | constitution, spec/code drift detection (`analyze`, `converge`) | many files per feature, GitHub is peripheral |

None drives GitHub Projects end to end, none pins models per role, none runs autonomously within
mechanical guardrails.

## 2. Goals and non-goals

Goals:
- Turn an idea into a prioritised, milestone-ordered GitHub Project of ready tickets, through a short
  interview that proposes alternatives and things the user did not think of.
- Deliver tickets with TDD, atomic conventional commits, small PRs, fresh-context review and green CI,
  interactively (`next`) or autonomously (`run`), day after day.
- Keep every change auditable: commit → PR → issue → spec → ADR.
- Spend tokens where they buy quality: cheap models for mechanics, strong ones for judgement.
- Scale ceremony to the task: a typo never gets an ADR.
- Use every Claude Code extension point where it beats prose instructions (section 16).

Non-goals:
- Not a project-management SaaS: GitHub is the only store of state.
- No estimation in hours or points; size S/M/L only.
- No hosting or deployment platform of its own; presets wire the user's existing one.
- No support for trackers other than GitHub in v1.

## 3. Users and journeys

| User | Typical day |
|---|---|
| Vibe coder (technical, undisciplined) | `/senior-mode:next` each morning; `/senior-mode:run` before leaving; reviews only what is labelled `needs-human` |
| Non-technical founder | `/senior-mode:frame` to turn an idea into tickets; `/senior-mode:status` to read where things stand; validates outcomes (scenario, preview), never code |
| Senior developer | Uses the guardrails and the agent team to delegate; tunes the config and principles |

Everything shown to the user is plain language first, technical detail second (section "Technical
detail" in issues and PRs). Every decision is presented as a table of alternatives with a
recommended option.

## 4. Principles

1. **Proportional process.** Triage decides the ceremony (section 5). KISS over completeness.
2. **One source of truth per kind of fact.** State lives in GitHub (Project, issues, PRs). Durable
   knowledge lives in the repository (specs, ADRs, `CLAUDE.md`). Nothing is duplicated.
3. **Mechanisms over prose.** A rule that can be checked by a hook, a CI job or a script is not written
   as an instruction. Prose is for judgement.
4. **Fresh eyes.** The author of tests is not the implementer; the reviewer starts from an empty
   context; the reviewer is never cheaper than the implementer.
5. **Proof before claims.** "Done" means verification commands were run and their output read.
6. **Least model that can do the job.** Pinned per role, escalated on failure (ADR 0004).
7. **Small and reversible.** One PR per ticket, ~400 changed lines at most excluding generated code.
8. **Ask, do not guess, when it matters.** Open product or architecture decisions are asked in batches
   of 3 to 4 questions, recommended option first; facts the code can answer are never asked.
9. **Lifecycle and roles, few skills.** Every skill is a step of the delivery lifecycle and a role of
   the team (section 8). A practice that fits no step is a section of an existing skill, or stays out
   (ADR 0009).
10. **Generic core, extension points.** No client, stack vendor or regulation in the core. Client
    needs go through `checks`, project skills and agents in the project's `.claude/`,
    `review.sections`, `docs.extra` and `envGuard.forbidden` (ADR 0010).
11. **Dogfooding before merge.** A command or skill is merged only after a real `claude -p` session on
    the sandbox repository exercised it; the PR records what was run and seen. `check` alone does not
    prove behaviour (ADR 0011).

## 5. Triage

Every request is classified before any work. The classification is written in the issue (`Size`).

| Size | Criteria (any one is enough for the higher size) | Ceremony |
|---|---|---|
| S | one module, < ~50 lines, no new dependency, no interface change, trivially reversible | branch + PR; no issue required, no spec; bug fixes still need a regression test |
| M | bounded feature or refactor, < ~400 lines, may add a dependency or change an internal interface | issue + light spec (`docs/specs`, problem, acceptance criteria, out of scope) + TDD + PR |
| L | new subsystem, data migration, public interface, hard-to-reverse choice, or > ~400 lines | `frame` mandatory: alternatives, ADR(s), full spec, epic issue split into sub-issues of size ≤ M; a human accepts spec and ADRs before implementation |

A ticket that grows past its size during work stops; the architect proposes a split.

## 6. Definitions of Ready and Done

**Ready** (required for `run`; checked by the `ready` skill, status `Ready` in the Project):
- linked spec, merged on the default branch, with acceptance criteria written as Given/When/Then;
- size S or M; no `needs-info` label; no open blocking dependency;
- test seams identified (where the tests will hook in);
- for an L epic: spec and ADRs `accepted`.

**Done:**
- verification commands green (lint, typecheck, tests, build) and run, not assumed;
- fresh-context review passed on both axes (spec, standards);
- PR merged with `Closes #n`, Project item `Done`, follow-up issues created for discovered work;
- spec status and `paths` updated in the same PR; ADR added for any new decision; `CLAUDE.md`
  updated if a command, the code map or a non-derivable pitfall changed.

## 7. Commands

Commands are user-invocable skills (`disable-model-invocation: true`), namespaced `/senior-mode:<name>`.
Natural-language triggers in any language route to them ("let's frame", "cadrons", "go", "enchaîne").

| Command | Purpose | Agents |
|---|---|---|
| `setup` | Adopt a repo (new or existing): detect stack, choose preset, create the Project and its fields, labels, branch protection, CI, release-please, git hooks, issue and PR templates, `CLAUDE.md` with Principles, `.claude/senior-mode.json`. Idempotent; re-run to repair. | scout, ops |
| `frame` | Idea → interview rounds → alternatives → spec → ADR(s) → tickets as vertical slices with acceptance criteria, dependencies, size, priority, milestone. Ends with a summary of proactive suggestions the user did not ask for. | scout, researcher, architect, ops |
| `next` | The daily session: short state of the board, open PRs needing a human, then picks the top Ready ticket and delivers it with the user in the loop (TDD, commits, PR). | ops, test-author, implementer, reviewer |
| `run` | Autonomous delivery of up to N Ready tickets (section 9). | all |
| `status` | Plain-language dashboard: done since last time, in progress, blocked, next, waiting for a human, release state. Cheap. | ops |
| `retro` | Weekly: reprioritise, close or rescope stale items, list debt, check spec drift, and turn recurring mistakes into mechanisms (a hook, a CI check, a lint rule) proposed as tickets. | architect, ops |

French is served without a companion plugin (ADR 0013): French trigger phrases in the skill
descriptions, and the `language` config key for replies and documents.

## 8. Lifecycle, roles and skills

Every skill is a step of the delivery lifecycle and a role of the team (ADR 0009). A practice that
fits no step is a section of an existing skill, or stays out of the plugin.

| Role | Step | Skills |
|---|---|---|
| Lead | Decide what to build and when it is ready | `triage`, `frame`, `spec`, `adr`, `grill`, `ready` |
| Developer | Build it | `tdd` (refactoring is a mode of it), `verify`, `commit` |
| Reviewer | Check it | `review` |
| Release and ops | Ship it, run the day | `run`, `next`, `status`, `docs` |
| Learning | Improve the method | `retro` |

The commands of section 7 are the user-invocable entry points of these steps. The disciplines below
are model-invoked, small (target < 3 KB each), loaded only when their description matches:

| Skill | Rule it carries |
|---|---|
| `triage` | Section 5 criteria and what each size requires |
| `ready` | Definition of Ready checklist; moves an item to `Ready` or labels it `needs-info` |
| `tdd` | Red first for logic and bugs (regression test mandatory); UI and glue covered by an end-to-end scenario per acceptance criterion; spikes exempt but discarded or tested before merge. Refactor mode: behaviour pinned by tests first, then structure changed in steps that each stay green |
| `commit` | Atomic conventional commits: one logical change, builds and passes on its own, body says why |
| `verify` | Run the project's verification commands and read the output before claiming success |
| `spec` | Spec template, lifecycle (`draft` → `accepted` → `implemented` → `superseded`), `paths` frontmatter, update in the same PR |
| `adr` | When an ADR is required, MADR-lite template, never edit an accepted ADR (supersede it) |
| `grill` | Interview protocol: decision frontier, 3-4 questions per round, recommended option first, facts fetched by `scout`, never ask what the repo answers |
| `review` | Two axes (spec conformance, standards: SOLID, KISS, DRY where it pays, naming, error handling, security, tests that test behaviour), plus sections loaded when relevant: explain (a change put in plain words), UI, and dependencies and data (licences, personal data). Projects add their own through `review.sections` (ADR 0010) |
| `docs` | Generic living documentation: README, architecture, user-facing changelog, ADRs; more through `docs.extra` |

## 9. Agent team

Pinned model and effort per role (ADR 0004). The orchestrating session stays thin: it routes,
it does not read code at length. Each agent serves one team role of section 8.

| Agent | Team role | Model / effort | Task | Tools |
|---|---|---|---|---|
| `scout` | Lead | haiku / low | Read the codebase, answer factual questions for interviews and planning | read-only |
| `researcher` | Lead | sonnet / medium | External docs, library comparison, prior art, with sources | read-only + web |
| `architect` | Lead | opus / high | Alternatives, ADRs, specs, vertical-slice decomposition, ticket splits | read + docs write |
| `test-author` | Developer | sonnet / medium | Failing tests from acceptance criteria, in the ticket's worktree | edit tests only |
| `implementer` | Developer | sonnet / medium → opus / high after 2 failed attempts | Make tests green, refactor, atomic commits | edit, bash |
| `reviewer` | Reviewer | opus / high | Fresh-context review on both axes, protected-zone check, merge verdict | read-only + gh |
| `ops` | Release and ops | haiku / low | Issues, Project fields, labels, PRs, CI status, merges, releases | gh, git |

## 10. Autonomy and guardrails

`run` merges by itself (ADR 0003) within these bounds:

- **Batch:** at most `autonomy.maxTickets` tickets (default 3), sequential by default, parallel worktrees
  only for tickets with no dependency between them (`autonomy.parallel`, default 1).
- **Circuit breaker:** stop after `autonomy.maxConsecutiveFailures` (default 2) failed tickets, or when
  a ticket outgrows its size; failed tickets go back to `Backlog` with a comment explaining why.
- **Protected zones** (globs in config, defaults per preset): data migrations; security, auth,
  permissions, secrets, payments; CI, infrastructure, container files, major dependency upgrades;
  any L ticket or ADR. Work there is implemented and reviewed but labelled `needs-human` and never
  merged by an agent.
- **Self-protection:** during a run, hooks deny edits to `.github/workflows/**`, `.claude/**`,
  `.githooks/**` and the protected-zone list itself, so an agent cannot weaken its own barriers.
- **Always denied:** `--no-verify`, force-push, direct push to the default branch,
  `gh pr merge --admin` or a PUT to the REST merge endpoint, history rewrite on shared branches,
  deleting files outside the ticket's worktree. The guard reads commands as written; it is a
  guardrail for honest mistakes, not a sandbox (GraphQL or `bash -c` are not parsed).

Run loop per ticket:
1. `ops` selects the top Ready item (Priority, then milestone due date), unblocked, size ≤ M.
2. Worktree and branch `<type>/<issue>-<slug>`; status `In progress`.
3. `test-author` writes failing tests from the acceptance criteria and records the failing output.
4. `implementer` makes them pass and refactors; tests land in the same commit as the code they cover,
   so every commit passes on its own (ADR 0005); the PR quotes the red run; `verify` before each push.
5. Spec updated if its `paths` are touched; PR opened from the template with `Closes #n`; status
   `In review`.
6. `reviewer` (fresh context) posts its review and sets the commit status `senior-mode/review`;
   at most 2 fix rounds.
7. Protected zone → `needs-human`, stop there. Otherwise `senior-mode check` runs on the PR head and
   publishes `senior-mode/ci`; once it and `senior-mode/review` are green, `ops` merges with
   `gh pr merge --rebase`. The `senior-mode` ruleset requires both statuses (ADR 0006).
8. Final report in plain language: merged, waiting for a human, failed and why, cost indicators.

`run` can also be scheduled headless (`claude -p`) for nightly batches, with the same config: by a
local scheduler (cron, systemd timer, launchd), a cloud scheduled task, or GitHub Actions in
`actions` mode.

## 11. GitHub model

- **Project (v2):** fields `Status` (Backlog, Ready, In progress, In review, Done), `Priority`
  (P0 now, P1 next, P2 later, P3 someday), `Size` (S, M, L). Built-in workflows set Done on merge.
- **Native features first:** milestones for roadmap stages (with due dates), sub-issues for epics,
  issue dependencies (blocked by) for ordering, issue types when the owner is an organization;
  on personal accounts, type labels `type:feature|bug|task|chore` replace issue types.
  `senior-mode issue create` sets fields, milestone, type, blocked-by and parent in one call, and
  reuses an open issue with the same title so an interrupted `frame` can be rerun.
- **Labels:** `needs-human`, `needs-info`, `blocked`, plus type labels when needed. Nothing else by
  default.
- **Branches:** short-lived, one per ticket, from the default branch.
- **Commits:** Conventional Commits, atomic, enforced by a `commit-msg` git hook and a CI check.
- **Merge:** rebase only, linear history, required checks (ADR 0005).
- **Release:** `senior-mode release` runs the release-please CLI locally after merges (the official
  action in `actions` mode); changelog and semver from commits.
- **Checks:** commit statuses `senior-mode/ci` (published by `senior-mode check`) and
  `senior-mode/review`, required on an up-to-date branch by a repository ruleset named `senior-mode`
  on the default branch (ADR 0006), which adds to any existing protection without rewriting it. A
  rebase onto a newer default branch drops `senior-mode/review`, so `run` reviews again after each
  merge. Admins may bypass the ruleset, explicitly (`gh pr merge --admin`); agents never may.
- **Titles:** issue and PR titles say what the user gets, in plain words, in the project language.

## 12. Documents in an adopted repository

```
CLAUDE.md                 ≤ 80 lines: commands, code map, non-derivable pitfalls, Principles section
docs/specs/NNNN-slug.md   one per M/L feature, frontmatter: id, title, status, size, paths, adrs, issue
docs/specs/INDEX.md       generated, never edited by hand
docs/adr/NNNN-slug.md     one decision each, MADR-lite, statuses proposed/accepted/superseded
.claude/senior-mode.json  project config (section 13)
.githooks/                commit-msg (Conventional Commits), pre-push (the check list); standalone,
                          so they work without Claude Code
.github/                  ci.yml, release-please, PR template, issue forms, CODEOWNERS, dependabot
CHANGELOG.md              generated by release-please
```

Anti-chaos rules, enforced in CI by the `senior-mode` script shipped in `bin/`:
- a PR touching the `paths` of an `accepted` or `implemented` spec must touch that spec, or say
  `Spec-Unchanged: <reason>` in its body;
- `INDEX.md` must be up to date; spec and ADR numbers unique; superseded documents point to their
  successor; no other documentation folder is created by the plugin.

## 13. Project config

`.claude/senior-mode.json`, written by `setup`, read by skills, hooks and the `bin/` script:

```json
{
  "language": "fr",
  "preset": "node",
  "commands": { "lint": "...", "typecheck": "...", "test": "...", "build": "..." },
  "project": { "owner": "...", "number": 1, "id": "PVT_...", "fields": { "Status": {"id": "...", "options": {}} } },
  "autonomy": { "maxTickets": 3, "parallel": 1, "maxConsecutiveFailures": 2, "autoMerge": true },
  "protected": { "migrations": [], "security": [], "infra": [] },
  "ci": { "mode": "local" },
  "limits": { "prLines": 400 }
}
```

Field and option ids are cached here so no agent rediscovers them with extra API calls.

## 14. Stack presets and CI

`setup` detects the stack and applies a preset; unknown stacks get the generic preset (commands asked
once, then stored).

| Preset | Lint / format | Types | Tests | Extra |
|---|---|---|---|---|
| node | Biome or the existing ESLint/Prettier | `tsc --noEmit` with TypeScript | Vitest, Playwright for e2e | Next.js aware |
| python | Ruff | mypy or pyright | pytest | uv |
| go | gofmt, golangci-lint | compiler | go test | |
| rust | rustfmt, clippy `-D warnings` | compiler | cargo test / nextest | cargo-deny |
| generic | asked | asked | asked | |

The node preset applies when a `package.json` exists and no preset is stored (a stored `typescript`,
its former name, becomes `node`). Its commands are the project's scripts (`lint`, `typecheck`,
`test`, `build`, `test:e2e` or `e2e`), run with the package manager of the lockfile; a tsconfig
without a typecheck script gets `tsc --noEmit` when `typescript` is a dependency, run so that it
never downloads a package. The report names the language: TypeScript when `typescript` is a
dependency or a tsconfig exists, else JavaScript, which expects no typecheck. A missing linter or
test runner is reported, and `setup` proposes Biome
or Vitest in a separate commit, never installed without a yes. Next.js is recorded as `framework`; it
builds through its script. Fixtures in `evals/fixtures/` are adopted and checked end to end by
`evals/run.sh` (network, run on demand before merging a change to presets).

Every preset defines one check list: lint, typecheck, tests, build, Conventional Commits, spec drift,
secret scanning. The pre-push hook runs it in any terminal; `senior-mode check` runs it in a session
(and before every merge in `run`) and records the result that `senior-mode publish` sends as the
commit status `senior-mode/ci`. `ci.mode` is `local` by default; `actions` also emits
the same list as a GitHub Actions workflow, with dependency review and caching. Dependabot (or
Renovate when present) and release-please are configured in both modes. An existing CI is extended,
never replaced; existing workflows are disabled, not deleted, in `local` mode (ADR 0006).

## 15. Token economy

- Skills are short; long references live in sibling files loaded only when needed.
- No session-start injection of large content: at most a ~15-line router.
- Facts come from `scout` (cheap) instead of the main session reading files.
- Config caches GitHub ids; `status` and `ops` work never use expensive models.
- Each ticket runs in a fresh context; the orchestrator keeps summaries, not transcripts.
- Verification output is filtered to failures before being shown to a model.

## 16. Claude Code surface map

Every extension point Claude Code offers, and what senior-mode does with it. "Not used" is a
decision, with its reason. Source: official docs (plugins reference, skills, sub-agents, hooks,
headless, GitHub Actions), November 2026.

### Plugin components

| Component | Use |
|---|---|
| `plugin.json` | Metadata, `userConfig` for per-user defaults (project language, autonomy defaults), `experimental.evals` |
| Skills | Commands (section 7) and disciplines (section 8) |
| Agents | The team (section 9) |
| Hooks (`hooks/hooks.json`) | Guardrails and proof mechanisms (below) |
| `bin/` | `senior-mode` script on the Bash PATH: config read, Project field helpers, spec index, drift check, run state, statusline output |
| Output styles | `senior-mode-plain`: outcome first, plain words, decisions as tables; offered to non-technical users, never forced |
| Monitors | `ci-watch` (`on-skill-invoke:run` and `next`): streams CI and review status of open PRs instead of polling; interactive sessions only |
| Workflows (`workflows/*.js`) | Candidate for a deterministic `run` loop instead of prose orchestration; spike in v0.3 |
| `${CLAUDE_PLUGIN_DATA}` | Run logs and cost reports per project, outside the repository |
| `.mcp.json` | Not used: the `gh` CLI covers GitHub without loading tool schemas into every context |
| `.lsp.json` | Not used: language tooling belongs to the project, not to the workflow |
| Themes, channels | Not used: no workflow value |

### Skill and agent frontmatter

| Field | Use |
|---|---|
| `disable-model-invocation` | All commands, so they run only when asked |
| `description`, `when_to_use` | Disciplines and natural-language triggers ("cadrons", "go", "enchaîne") |
| `argument-hint`, `arguments` | `frame <idea>`, `run [n]`, `next [#issue]` |
| `model`, `effort` on skills | `status` on haiku/low |
| `context: fork` | `status` and `retro` run in a forked context and return a summary, keeping the main context clean |
| `allowed-tools`, `disallowed-tools` | Read-only for `status`. Not for `frame`: `allowed-tools` only pre-approves and `disallowed-tools` lapses at the next message, so a hook keeps frame to `docs/` (#36) |
| `paths` | Disciplines loaded only near relevant files (`spec` near `docs/specs/**`, `adr` near `docs/adr/**`) |
| Agent `model`, `effort` | Pinned per role (ADR 0004) |
| Agent `tools`, `disallowedTools` | Least privilege per role (section 9) |
| Agent `skills` | Preloaded disciplines: implementer gets `tdd`, `commit`, `verify`; reviewer gets `review`, `spec` |
| Agent `maxTurns` | Cost cap per role, part of the circuit breaker |
| Agent `memory: project` | `reviewer` and `architect` keep recurring findings, fed into `retro` |
| Agent `omitClaudeMd` | `ops` skips `CLAUDE.md`: it never needs the code map |
| Agent `isolation: worktree` | Parallel tickets get one worktree each; agents of the same ticket share it |
| Agent `color` | One per role, readable in the transcript |

Plugin agents ignore `hooks`, `permissionMode` and `mcpServers`: guardrails therefore live in the
plugin's hooks, which cover every agent.

### Hooks

| Event | Handler | Purpose |
|---|---|---|
| `SessionStart` | command | Inject a ~15-line router and, from the branch name, the current ticket, its spec and its state |
| `PreToolUse` Bash | command | Deny `--no-verify`, force-push, push to the default branch, `reset --hard` on shared branches |
| `PreToolUse` Edit/Write | command | During a run, deny protected and self-protecting paths (section 10); in a frame session, deny edits outside `docs/`, subagents included |
| `UserPromptExpansion`, `PreToolUse` Skill, `SessionEnd` | command | Mark a frame session when `frame` starts; clear it on another senior-mode command or skill, at session end, or with `senior-mode frame end` |
| `PermissionRequest` | command | During a run, allow the project's verification commands from config, so autonomy does not stall on prompts |
| `PostToolUse` Edit/Write | command | Run the preset's formatter on the edited file; mark "verification needed" |
| `Stop`, `SubagentStop` | command | Block `implementer` and `next` from ending with edits made since the last successful verification (proof before claims, mechanised) |
| `PreCompact` | command | Compaction keeps ticket, spec, decisions taken, verification state |
| `Notification` | command | Optional desktop notification when a human is needed |
| `prompt` and `agent` handlers | not used | They cost tokens on every event; command handlers suffice |

### Beyond the plugin

| Feature | Use |
|---|---|
| Project settings (`.claude/settings.json`), written by `setup` | Permission allow-list for verification and read-only `gh` commands, deny-list mirroring the hooks; optional statusline running `senior-mode statusline` (current ticket, run progress) |
| `.claude/rules/*.md` with `paths` | Stack conventions from the preset, so `CLAUDE.md` stays under 80 lines |
| Sandbox | `setup` offers to enable it for runs where available |
| Headless (`claude -p`) | `run` without a session: `--max-turns`, `--max-budget-usd`, `--output-format json` for the cost report |
| GitHub Action (`claude-code-action`) | `actions` mode only (ADR 0006): nightly scheduled `run` with the plugin installed; `@claude` in an issue lets a non-technical user answer `needs-info` or ask for framing from GitHub, including on mobile |
| Cloud scheduled tasks | Alternative to Actions for nightly runs, where the plan allows it |
| `claude plugin validate`, `claude plugin eval` | Plugin CI (section 18) |
| Checkpoints, `/loop`, agent teams | Not relied upon: subagent and Bash edits are not restored by checkpoints (commits are the checkpoints), monitors replace polling loops, agent teams are experimental |

## 17. Plugin repository layout

```
.claude-plugin/marketplace.json     marketplace listing
plugins/senior-mode/
  .claude-plugin/plugin.json
  skills/<command>/SKILL.md         setup, frame, next, run, status, retro
  skills/<discipline>/SKILL.md      triage, ready, tdd, commit, verify, spec, adr, grill, review;
                                    a skill's own templates sit next to it (spec, adr)
  agents/*.md                       section 9
  hooks/hooks.json, hooks/*.sh      sections 10 and 16
  bin/senior-mode                   index, drift check, config read, Project helpers, ticket creation, statusline
  output-styles/senior-mode-plain.md
  monitors/monitors.json            ci-watch
  templates/                        spec, ADR, CLAUDE.md, rules, settings, PR and issue templates,
                                    githooks, GitHub Action for scheduled runs
  presets/<stack>/                  CI workflow, commands, protected-zone defaults
evals/                              triage, readiness, grill and end-to-end cases
docs/specs/, docs/adr/              this project's own specs and ADRs
```

## 18. Quality of the plugin itself

- Checks (`senior-mode check`, run locally; the workflows in `.github/` are the disabled `actions`
  mode): `claude plugin validate --strict` on the plugin and the marketplace, shellcheck on hooks and
  `bin/`, unit tests of `bin/senior-mode` and of each hook (JSON in, decision out), size budget per
  skill, agent pins of ADR 0004, Conventional Commits, spec drift.
- Evals (`claude plugin eval`, with a cost cap): fixed cases for triage (S/M/L), Definition of Ready,
  interview quality, and an end-to-end run on a fixture repository (setup → frame → run) checked on
  artefacts, not on prose. Run on release PRs, not on every PR.
- Dogfooding: senior-mode is built with senior-mode from v0.1 on.

## 19. Delivery plan

| Milestone | Content |
|---|---|
| v0.1 Bootstrap | Plugin skeleton, `setup` (generic + node presets), `frame`, discipline skills, agents, hooks; written by hand, then used to plan the rest |
| v0.2 Daily loop | `next`, `status`, spec index and drift check, git hooks |
| v0.3 Autonomy | `run`, review status check, protected zones, circuit breaker, scheduled run in Actions |
| v0.4 Breadth | python, go, rust presets, `retro`, `senior-mode-fr` |
| v1.0 | Evals green, docs, marketplace publication |

## 20. Open questions

- `run` orchestration: prose skill driving agents, or a `workflows/*.js` script (spike in v0.3).
- Statusline: plugins cannot ship one, and `bin/` is on the PATH of the Bash tool, not necessarily
  of the statusline command; find a project setting that survives plugin updates (the plugin root
  path changes on each update).
- Credentials for scheduled runs in Actions (API key or OAuth token) and the default
  `--max-budget-usd`.
- Whether `status` should also write a weekly digest issue for non-technical stakeholders.
