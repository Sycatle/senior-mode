---
id: 0001
title: senior-mode, a Claude Code plugin for senior-grade delivery
status: accepted
size: L
paths: ["plugins/**", ".claude-plugin/**", "evals/**"]
adrs: [0001, 0002, 0003, 0004, 0005, 0006, 0007, 0008, 0009, 0010, 0011, 0012, 0013, 0014]
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
| `next [#issue]` | The daily session: short state of the board, open PRs needing a human (offered for review or merge first), then picks the top Ready ticket and delivers it with the user in the loop (TDD, commits, PR, review). Never merges without the user's explicit yes. | ops, test-author, implementer, reviewer |
| `run` | Autonomous delivery of up to N Ready tickets, one headless session per ticket (section 10, ADR 0007). | all |
| `status` | Plain-language dashboard: done since last time, in progress, blocked, next, waiting for a human, release state. Cheap: one GraphQL call. | none (runs `senior-mode status`) |
| `retro` | The learning step, weekly by default: the facts of the period in plain language, then at most three process changes (a `CLAUDE.md` pitfall, a protected glob, a check, a ticket split rule) proposed as issue drafts the user approves. Edits nothing without a yes. | none (runs `senior-mode retro`) |

French is served without a companion plugin (ADR 0013): French trigger phrases in the skill
descriptions, and the `language` config key for replies and documents.

### `pick`, `start`, `status` and the statusline

- `senior-mode pick [--json] [--max N]` is the one ticket selection that `next` and `run` share. It lists
  the Ready items of the Project, open, ordered by Priority (P0 first), then milestone due date (none
  last), then number. It leaves out size L, tickets with an open "blocked by" link or the `blocked`
  label, and tickets with `needs-info` (a Ready ticket should not have it; the label wins).
- `senior-mode start <issue>` is the other step `next` and `run` share: it creates the worktree next to
  the main checkout (`<repository>-<issue>`) and the branch `<type>/<issue>-<slug>`, from the default
  branch fetched first (no upstream is set), then sets Status `In progress`. The type follows the
  issue's `type:` label (`feature` feat, `bug` fix, `task` and `chore` chore; feat without a label); the
  slug is the title without its Conventional prefix, cut at 40 characters on a word. It refuses a
  closed issue or a taken path, and rerunning reuses the branch (whatever its slug) and the worktree.
  It prints `branch <name>` and `worktree <path>`.
- `senior-mode status [--json] [--since <dur>] [--watch [secs]]` reads the Project items and the
  repository facts (open pull requests with their statuses, recently closed issues and merged pull
  requests, the latest release) in one GraphQL query; only a Project of more than 100 items takes
  another call. Sections: done, in progress, in review, blocked or missing information (`blocked` or
  `needs-info` label, an open dependency on a ticket already started), waiting for a human
  (`needs-human` pull requests and tickets, failing statuses), next Ready (top three of `pick`),
  release (latest release, open release pull request).
- A plain run reports what is new since the previous plain run (first run: seven days) and then moves
  that mark, kept in `.claude/senior-mode/status-seen`, a directory that ignores itself so `check` still
  sees a clean tree. `--since 7d` (`m`, `h`, `d`, `w`) is the digest for a reader who is not
  technical, and, like `--json` and `--watch`, leaves the mark alone. `--watch` redraws every 30
  seconds (or `secs`) for a terminal or tmux pane. A weekly digest issue is not created: the
  digest is on demand, and `docs/changelog.md` keeps the history.
- `senior-mode statusline` prints one line, offline: ticket of the branch (or the branch), last check
  recorded for the tree (`check ok`, `check FAILED`, `check stale` after an edit, `no check`) and
  `run in progress` when `SENIOR_MODE_RUN` is set. Claude Code runs it from the project's
  `.claude/settings.json`, written by `senior-mode setup statusline` (offered by `setup`).
  A plugin cannot ship a status line, and `bin/` is on the PATH of the Bash tool, not of the status
  line command, so the setting holds a short command that finds the script at each run: the
  `installPath` of `senior-mode@*` in `~/.claude/plugins/installed_plugins.json`, else the newest
  `~/.claude/plugins/cache/*/senior-mode/*/bin/senior-mode`. No path or version is stored, so plugin
  updates do not break it; it prints nothing if the plugin is not installed (a plugin loaded with
  `--plugin-dir` is in neither place). A project setting hides the user's own status line in that
  project, so `setup` asks first and keeps a status line the project already has.

`next` runs in this order: `status` (five lines at most), then the pull requests that need the user
(`needs-human`, reviewed and green, failing), each offered for review by the `reviewer` agent or for
merge; then `pick --max 1` (or the ticket given, if Ready), confirmed by the user; `start`;
`test-author` (red run kept), `implementer` (atomic commits, `check`), the pull request from the
template with `Closes #n`, Status `In review`, `publish`, the `reviewer` (at most two fix rounds). A
merge needs the user's explicit yes in the conversation, both statuses green and no `needs-human`
label; a `needs-human` pull request is merged by the user, never by an agent. After the merge `next`
invokes the `docs` skill (section 8) and offers the next ticket. Its long reference sits next to the
skill, in `skills/next/reference.md`.

### `retro`

- `senior-mode retro [--since <dur>] [--json]` gathers the facts of a period (default 7 days) and
  changes nothing. It reuses the board query of `status` and adds one history query: issues updated
  in the period with their status changes and reopenings, and recently merged pull requests with
  their size, labels and reviews. Two GitHub calls, three for a Project of more than 100 items.
- Facts: tickets done (not those closed as not planned); cycle time, from the first move to
  `In progress` to the close of the ticket, as median and worst (a ticket with no recorded start is
  left out); pull requests that needed a human, open or merged in the period (`needs-human` label, or
  a review requesting changes, with its first words as the reason); reopened tickets; failed results
  `check` recorded locally (ADR 0006), in the repository and its worktrees; failed or escalated runs;
  and size against reality: a ticket's pull request lines against its size (S ~50, M ~400, section
  5), over when above 1.5 times that.
- Run logs are optional: `.claude/senior-mode/runs/*.json`, one object per ticket run with `ticket`,
  `outcome` (`done` or `failed`), `escalated`, `reason`, `finishedAt`. `run` writes them (open
  question: its log format is not settled yet; `retro` reads these keys and skips what it cannot
  read). Without the directory, `runs.found` is false and the command still works.
- The skill answers in the `language` of the config, then proposes at most three changes, each an
  issue draft with its evidence; it creates an issue, edits a file or a config only after a yes.

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
are model-invoked, small (target < 3 KB each), loaded only when their description matches. A skill keeps
details in sibling Markdown files that it reads only when they apply:

| Skill | Rule it carries |
|---|---|
| `triage` | Section 5 criteria and what each size requires |
| `ready` | Definition of Ready checklist; moves an item to `Ready` or labels it `needs-info` |
| `tdd` | Red first for logic and bugs (regression test mandatory); UI and glue covered by an end-to-end scenario per acceptance criterion; spikes exempt but discarded or tested before merge. Refactor-only ticket mode: invariant first, characterization tests when coverage is weak, small green steps, `refactor:` commits, no behaviour change |
| `commit` | Atomic conventional commits: one logical change, builds and passes on its own, body says why |
| `verify` | Run the project's verification commands and read the output before claiming success |
| `spec` | Spec template, lifecycle (`draft` → `accepted` → `implemented` → `superseded`), `paths` frontmatter, update in the same PR |
| `adr` | When an ADR is required, MADR-lite template, never edit an accepted ADR (supersede it) |
| `grill` | Interview protocol: decision frontier, 3-4 questions per round, recommended option first, facts fetched by `scout`, never ask what the repo answers |
| `review` | Two axes (spec conformance, standards: SOLID, KISS, DRY where it pays, naming, error handling, security, tests that test behaviour), plus sections read only when they apply: the plain-language brief for the person who merges (always, in the PR comment), UI (when the diff touches front-end files), dependencies and data (licences, secrets and personal data in logs and exports, new third-party services), and the project's own `review.sections` |
| `docs` | Living docs, the step after a merge: updates only what the merged change made stale (README usage and setup, `docs/architecture.md`, links to new ADRs), adds a plain-language entry to `docs/changelog.md`, and keeps the project's `docs.extra` documents current, flagged for human review. Own `docs:` PR, never invents facts (unknowns are "To confirm"), digests a period from the changelog |

`docs` is called after a merge: `run` calls it once at the end of a run for every PR the run merged,
and `next` calls it after the user merges the ticket's PR. Neither waits for the resulting PR. A PR
from a `docs/after-pr-*` branch is never documented in turn, and an open docs PR receives new commits
instead of a second PR. The core carries no client, stack or regulation wording: a client's
governance or audit document is an `extra` entry, its changes sit in a separate commit, the PR gets
`needs-human`, and the body lists them under "For human review".

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
| `reviewer` | Reviewer | opus / high | Fresh-context review on both axes, brief for the person who merges, protected-zone check, applicable sections, merge verdict | read-only + gh |
| `ops` | Release and ops | haiku / low | Issues, Project fields, labels, PRs, CI status, merges, releases | gh, git |

## 10. Autonomy and guardrails

`run` delivers tickets up to green, reviewed pull requests. It merges them by itself only when
`autonomy.merge` is true (default false, ADR 0008, which narrows ADR 0003), and then only within
these bounds:

- **Batch:** at most `autonomy.maxTickets` tickets (default 3), sequential by default, parallel worktrees
  only for tickets with no dependency between them (`autonomy.parallel`, default 1).
- **Circuit breaker:** stop after `autonomy.maxConsecutiveFailures` (default 2) failed tickets, or when
  a ticket outgrows its size; failed tickets go back to `Backlog` with a comment explaining why.
- **Model escalation:** a ticket that fails on Sonnet is retried once on Opus before it counts as a
  failure for the circuit breaker (`autonomy.escalate`, default true, ADR 0014).
- **Protected zones** (`protected`, globs in config, defaults per preset): data migrations; security,
  auth, permissions, secrets, payments; CI, infrastructure, container files, major dependency upgrades;
  any L ticket or ADR. Work there is implemented and reviewed but labelled `needs-human` and never
  merged by an agent. `senior-mode protected [--base <ref>]` lists the files of the branch (changed
  since the merge-base with the base, by default the default branch) that match a glob: exit 0 with
  the matches, 1 with none. The `reviewer` runs it: a match means `needs-human` and `senior-mode/review`
  stays `pending`; the globs are a floor, and the reviewer still judges what they miss (major
  upgrades, L tickets, ADRs). A glob without a slash matches a name at any depth; one with a slash is
  anchored at the repository root, where `*` stays in one segment, `**/` spans directories and `?` is
  one character. The presets `node` and `generic` declare defaults under `protected` in `preset.json`;
  `setup` writes them when the key is absent and never touches a list already there, even an empty one.
- **Self-protection:** while `SENIOR_MODE_RUN=1`, a hook denies Edit, Write, MultiEdit and
  NotebookEdit on `.github/workflows/**`, `.claude/**` and `.githooks/**` (the config, and so the
  protected-zone list, lives in `.claude/`) except `.claude/agent-memory/**` (the project memory of
  the reviewer and architect agents), and Bash commands that obviously write there
  (redirections, `tee`, `cp`, `mv`, `rm`, `sed -i`, `git rm`...), so an agent cannot weaken its own
  barriers. Outside a run it does nothing. Like the Bash guard it is a guardrail for honest mistakes,
  not a sandbox.
- **Always denied:** `--no-verify`, force-push, direct push to the default branch,
  `gh pr merge --admin` or a PUT to the REST merge endpoint, history rewrite on shared branches,
  deleting files outside the ticket's worktree. The guard reads commands as written; it is a
  guardrail for honest mistakes, not a sandbox (GraphQL or `bash -c` are not parsed).
- **Secrets guard:** always on, run or not. A `PreToolUse` hook (`guard-secrets.sh`) denies `Read`, `Grep`
  and `Glob` on `.env`, `.env.*` (except `.env.example`, `.env.sample`, `.env.template`), `*.pem`, `*.key`,
  `id_rsa*`, `id_ed25519*` (public `.pub` keys are fine), `*.p12`, `*.pfx`, `.npmrc`, `.netrc`,
  `credentials*.json`, `service-account*.json` and the globs of the config key `secrets`; and Bash commands
  that dump them (`cat`, `less`, `head`, `tail`, `grep`, `source`, `.` and similar) or the environment
  (`printenv`, bare `env`, bare `set`, `export -p`, `declare -x`, `/proc/*/environ`). The deny reason says
  why and what to do instead: ask the human, read `.env.example`. Same stance as the Bash guard: honest
  mistakes, not a sandbox (`bash -c`, scripts and `cat *` are not parsed). `setup` advises keeping only
  dev-only secrets on a machine where agents run.

`senior-mode run [--max N] [--parallel P]` orchestrates (ADR 0007): the bounds above, the retries and
the merge are applied by the command, not by a model. It takes the first N tickets of `pick`, and
for each, at most P at a time:

- creates the worktree `<repo>-run-<n>` (a sibling of the main checkout) and the branch
  `<type>/<issue>-<slug>` from the default branch (`fix` for `type:bug`, `chore` for `type:chore`,
  else `feat`), or reuses them, and sets the status `In progress`;
- starts `claude -p --model sonnet --permission-mode bypassPermissions` in it, with
  `SENIOR_MODE_RUN=1` and `SENIOR_MODE_RUN_OUTCOME` (and `--plugin-dir` from
  `SENIOR_MODE_PLUGIN_DIR`), in a window of the tmux session `senior-mode-run`, or in the background
  without tmux; scripts, prompts and logs go to `.git/senior-mode/runs/<stamp>/`;
- reads the outcome line the session writes: `delivered` (it counts only with an open pull request
  for the branch), `outgrown: <reason>` (stops the run) or `failed: <reason>`; a missing line is a
  failure. A failure on Sonnet is retried once on Opus from the same worktree when
  `autonomy.escalate` is true (default). A ticket given up goes back to `Backlog` with a comment;
- merges a delivered pull request only when `autonomy.merge` is true, `senior-mode/ci` and
  `senior-mode/review` are both `success` on its head, it has no `needs-human` label and
  `github.protection` is not `none`; after any merge, one more session updates the living docs on a
  branch of its own;
- the check named `e2e` runs through `senior-mode e2e-lock`, at most `e2e.slots` (default 2) at once
  per machine, the slot number in `SENIOR_MODE_E2E_SLOT`.

`run` refuses to work as root (Claude Code does not skip permission prompts for root) and finds
`claude` on PATH or in `~/.local/bin`.

Each ticket session:
1. Reads the ticket, its spec and acceptance criteria (the command already picked it and set it
   `In progress`).
2. Works in its worktree on branch `<type>/<issue>-<slug>`.
3. `test-author` writes failing tests from the acceptance criteria and records the failing output.
4. `implementer` makes them pass and refactors; tests land in the same commit as the code they cover,
   so every commit passes on its own (ADR 0005); the PR quotes the red run; `verify` before each push.
5. Spec updated if its `paths` are touched; PR opened from the template with `Closes #n`; status
   `In review`.
6. `reviewer` (fresh context) posts its review and sets the commit status `senior-mode/review`;
   at most 2 fix rounds.
7. Protected zone → `needs-human`, stop there. `senior-mode check` runs on the PR head and publishes
   `senior-mode/ci`; the session writes its outcome line and never merges. The `senior-mode` ruleset
   requires both statuses (ADR 0006).
8. The command's final report in plain language: merged, waiting for a human and why, failed and
   why, not started.

`run` can also be scheduled headless (`claude -p`) for nightly batches, with the same config: by a
systemd user timer or cron entry on the agent machine, using the machine's subscription login: no API
key, no budget flag (ADR 0012). A cloud scheduled task, or GitHub Actions in `actions` mode, remain
possible alternatives (ADR 0006).

`senior-mode schedule install [--at HH:MM] [--max N]`, `remove` and `status` manage that schedule for
the repository. The time is `--at`, else `autonomy.schedule`, else `02:00`. Install writes
`senior-mode-run-<repo>.service` and `.timer` in `~/.config/systemd/user/` (`OnCalendar` daily,
`Persistent=true`), runs the command through `bash -lc` so `claude` is on `PATH`, and enables the timer
with `systemctl --user`. Where `systemctl --user` is unavailable it adds a crontab line tagged
`# senior-mode-run:<repo>`, logging to `.git/senior-mode/schedule.log`. It refuses root, and warns with
the exact `sudo loginctl enable-linger <user>` when linger is off, since the timer would then fire only
during a login session. Install and remove are idempotent; `status` prints the next trigger and the
last result.

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
- **GitHub Free fallback:** on a private repository of a Free account or organization, the rulesets
  API answers HTTP 403 ("Upgrade to GitHub Pro or make this repository public to enable this
  feature."). `setup` detects it on the status and a stable fragment of that message, skips the ruleset
  and finishes the rest. It sets `ci.mode` to `local` (the pre-push hook is then the only gate),
  records `github.protection: "none"` (§13) and warns in plain words: protection is not enforced on
  the server, anyone with push access can push to the default branch; make the repository public,
  upgrade to Pro or Team, or accept the local gate. The setup skill relays the warning and asks the
  user to acknowledge it. Any other refusal stops `setup`. A later run on a plan that allows rulesets
  creates the ruleset and records `"ruleset"`; `ci.mode` is not changed back.
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
docs/architecture.md      system overview (components, data flow, external services, ADR links); created
                          by setup from a template, kept current by the `docs` skill
docs/changelog.md         plain-language entry per merged PR (what changed for users, date, link), written
                          by the `docs` skill; distinct from release-please's CHANGELOG.md
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
  "autonomy": { "maxTickets": 3, "parallel": 1, "maxConsecutiveFailures": 2, "merge": false, "escalate": true },
  "e2e": { "slots": 2 },
  "protected": ["**/migrations/**", "**/auth/**", ".github/workflows/**", "Dockerfile*"],
  "secrets": ["config/prod.*", "**/vault/*"],
  "review": { "sections": ["docs/review/payments.md"] },
  "ci": { "mode": "local" },
  "github": { "protection": "ruleset" },
  "envGuard": { "forbidden": ["db.prod.example.com", "/acct-[0-9]{12}/"] },
  "limits": { "prLines": 400 },
  "docs": { "extra": [ { "path": "docs/runbook.md", "purpose": "How to operate and restore the service" } ] }
}
```

`docs.extra` is optional: extra living documents, each a path and a one-line purpose, that the `docs`
skill keeps current after a merge, with changes flagged for human review. `language` (`en` or `fr`)
sets the language of the templates and of what the skills write.

Field and option ids are cached here so no agent rediscovers them with extra API calls.
`github.protection` is written by `setup github`: `"ruleset"` when the `senior-mode` ruleset is in
place, `"none"` when the plan refused it (§11), so status and governance documents can say whether
the default branch is protected on the server.

`secrets` lists globs the secrets guard denies on top of its defaults (section 10): a glob without a slash
matches the file name, one with a slash matches the path from the repository root, `**/` standing for any
directories. It only adds; there is no way to allow a default.

`envGuard.forbidden` lists what must never appear on an agent machine: a production database host,
a project ref, an account id. An entry is a literal string, or an extended regular expression
between slashes (`/.../`). When the list is not empty, `setup` installs `.githooks/env-guard.sh` and
adds the check `env guard` (§14); the rule itself, development environments only, is a line of the
`Principles` block of `CLAUDE.md`. The key names no vendor and no stack: the project says what is
forbidden.

`review.sections` is the extension point for checks that belong to one project (regulated, stack- or
company-specific): a list of project-relative Markdown checklists. The `review` skill reads each one
from the base branch and applies it as an extra section, so a pull request cannot edit the checks it
is judged by. The plugin ships none; they live in the project's repository.

## 14. Stack presets and CI

`setup` detects the stack and applies a preset; unknown stacks get the generic preset (commands asked
once, then stored).

| Preset | Lint / format | Types | Tests | Extra |
|---|---|---|---|---|
| node | Biome or the existing ESLint/Prettier | `tsc --noEmit` with TypeScript | Vitest, Playwright for e2e | Next.js aware |
| python | Ruff or flake8; black or `ruff format` | mypy or pyright | pytest | `python -m build`; uv, poetry |
| go | `go vet`, golangci-lint when configured | compiler | go test | `go build` |
| rust | `cargo fmt --check`, clippy `-D warnings` | compiler | cargo test | `cargo build` |
| generic | asked | asked | asked | |

The node preset applies when a `package.json` exists and no preset is stored (a stored `typescript`,
its former name, becomes `node`). Its commands are the project's scripts (`lint`, `typecheck`,
`test`, `build`, `test:e2e` or `e2e`), run with the package manager of the lockfile; a tsconfig
without a typecheck script gets `tsc --noEmit` when `typescript` is a dependency, run so that it
never downloads a package. The report names the language: TypeScript when `typescript` is a
dependency or a tsconfig exists, else JavaScript, which expects no typecheck. A missing linter or
test runner is reported, and `setup` proposes Biome
or Vitest in a separate commit, never installed without a yes. Next.js is recorded as `framework`; it
builds through its script, and `middleware.*` and `src/middleware.*` join the default `protected`
globs: the preset declares such framework defaults under `frameworks` (its top-level `protected`
list stays the stack-wide one). Fixtures in `evals/fixtures/` are adopted and checked end to end by
`evals/run.sh` (network, run on demand before merging a change to presets).

The other presets apply when no `package.json` exists and no preset is stored, in this order:
`go.mod` (go), `Cargo.toml` (rust), then `pyproject.toml`, `setup.py` or `requirements.txt` (python);
a `requirements.txt` is common in any repository, so Python's files come last. A stored preset wins.
Their commands come from what the project uses, and a tool the project does not use gets no check.
python: `ruff check .` or `flake8`; `black --check .`, else `ruff format --check .` when Ruff is used;
`mypy .` or `pyright`; `pytest`; `python -m build` when `pyproject.toml` has a `[build-system]`.
Each is prefixed with `uv run` when `uv.lock` exists, `poetry run` when `poetry.lock` exists. A tool
counts as used when its config file exists or its name is a word of the manifests (`pyproject.toml`,
`setup.cfg`, `setup.py`, `tox.ini`, `Pipfile`, `requirements*.txt`). go: `go vet ./...`, joined by
`golangci-lint run` when a `.golangci.{yml,yaml,toml,json}` exists; `go test ./...`; `go build ./...`.
rust: `cargo clippy --all-targets -- -D warnings`, `cargo fmt --check`, `cargo test`, `cargo build`.
The release-please type is `python`, `go` or `rust`. Each preset carries default `protected` globs
(migrations, auth and security directories, CI workflows, Dockerfiles, compose files and `infra/`;
lockfiles are not protected) in its `preset.json`; reading them is the protected zones' job.

Every preset defines one check list: lint, typecheck, tests, build, Conventional Commits, spec drift,
secret scanning, plus the environment guard when `envGuard.forbidden` is set: it fails when a
forbidden pattern appears in a `.env*` file of the worktree, tracked or not, or in the environment,
and prints file names and variable names, never a value. A check whose first output line is
`skipped: <reason>` passes and is shown as `skip <name>: <reason>`. The pre-push hook runs it in any
terminal; `senior-mode check` runs it in a session
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
| `PreToolUse` Edit/Write/Bash | command | During a run (`SENIOR_MODE_RUN=1`), deny writes to `.github/workflows/**`, `.claude/**`, `.githooks/**` (section 10, `self-protect.sh`) |
| `PreToolUse` Edit/Write | command | In a frame session, deny edits outside `docs/`, subagents included |
| `PreToolUse` Read/Grep/Glob/Bash | command | Deny reading `.env` files, keys and credential files, and dumping the environment, in every session (section 10) |
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
| Project settings (`.claude/settings.json`), written by `setup` | Permission allow-list for verification and read-only `gh` commands, deny-list mirroring the hooks; optional statusline running `senior-mode statusline` (current ticket, last check, run in progress), written by `senior-mode setup statusline` (§7) |
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
  skills/<discipline>/SKILL.md      triage, ready, tdd, commit, verify, spec, adr, grill, review, docs;
                                    a skill's own templates sit next to it (spec, adr), long
                                    guidance in a sibling reference.md (docs)
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
| v0.2 to v0.4, shipped together | Daily loop: `next`, `status`, spec index and drift check, git hooks. Autonomy: `run`, review status check, protected zones, circuit breaker, model escalation, scheduled runs on the agent machine. Breadth: python, go, rust presets, `retro`, generic `docs`, French triggers. Each piece passes the dogfooding gate (ADR 0011) before it is merged |
| v1.0 | Evals green, marketplace publication |

## 20. Open questions

None open.
