# Commands

Every `/senior-mode:` command, what it asks you and what it produces, plus the `senior-mode` script.

Commands run only when you type them. The design is in [spec §7](../specs/0001-senior-mode.md#7-commands).
You need three of them: `frame`, `go` and `status` ([ADR 0031](../adr/0031-three-verbs.md)). `setup`
and `retro` start on their own and stay callable.

## Overview

| Command | Purpose | State |
|---|---|---|
| `/senior-mode:frame` | Turn an idea into a spec, ADRs and tickets | Available |
| `/senior-mode:go` | Deliver the next ticket with you, or start or follow the daemon | Available |
| `/senior-mode:status` | Plain-language dashboard | Available |
| `/senior-mode:setup` | Adopt a repository, or repair it; the first `go` runs it | Available |
| `/senior-mode:retro` | Weekly review of the board and the process; `status` offers it | Available |

## `setup`

State: **Available.**

- **Purpose.** Adopt a repository, new or existing. Safe to re-run: it repairs, never duplicates.
- **Asks you.** Whether to create a GitHub repository if there is none (private by default); to run
  `gh auth refresh -s project` if the scope is missing; three questions, after detecting the stack, the
  visibility and plan of the repository and the language of your `CLAUDE.md` (how strict the process is,
  which language, whether agents may work alone), each with a recommended answer and what it changes;
  your yes to one summary of the answers and the documented defaults (checks `local`; `actions` only when
  you ask); for a stack without a `package.json`, how to lint, typecheck,
  test and build; your yes before adding a missing linter or test runner.
- **Produces.** A Project board with `Status`, `Priority`, `Size`, `Severity` and the text field `Paths`; labels; rebase-only merges;
  the `senior-mode` ruleset; `.github/CODEOWNERS` for the protected zones; Dependabot alerts, secret scanning and push protection (where the plan allows); `.claude/senior-mode.json`; git hooks; `CLAUDE.md` Principles; PR and
  issue templates; permissions; release-please config; in `actions` mode, a workflow; on a Free plan that refuses rulesets, the audit workflow `senior-mode-audit.yml`. Ends with a
  plain summary and the Project URL.

Details: [Getting started](getting-started.md#adopt-a-repository).

## `frame`

State: **Available.**

```
/senior-mode:frame <the idea, in a sentence or two>
```

- **Purpose.** Size a request, then turn it into a delivered change (S) or into decisions, a spec,
  ADRs and Ready tickets (M, L). A request in plain words is enough ("je veux", "on devrait",
  "ajoute", "I want", "we should"): Claude starts `frame` by itself. A question, a review or a status
  request is not a product request, and a bug report goes through `triage`. Typing the command is
  the explicit form.
- **Size.** Judged with the `triage` criteria and announced in one line with its reason, before any
  work. A smaller size than the criteria allow is refused with the criterion that forbids it; a
  larger one is accepted.
- **Asks you.** Always one round of 3 to 4 questions, even for S, recommended option first, then only
  what stays open and what the repository and GitHub cannot answer. For M and L, then whether you
  accept the spec and ADRs. With nobody to ask (headless), the recommended options are taken and
  recorded as assumed; an L spec and any ADR stay `draft` / `proposed`, with `needs-human`.
  When `docs/vision.md` exists (the owner's goals `G1`... and `## Non-goals`), an idea that contradicts a
  non-goal is not framed: `frame` quotes the non-goal and asks you; headless, it labels the issue
  `needs-human` and stops.
  Each question and the option chosen are appended with the date to `docs/decisions.md` (the decision
  log, written with `senior-mode frame decide`) and cited in a `## Framing` section of the ticket body.
- **Produces.** A spec in `docs/specs/` (light for M, full for L), ADRs in `docs/adr/`, tickets on
  the board as vertical slices (size, priority, milestone, Given/When/Then criteria, test seams,
  blockers; an epic with sub-issues for L), and a pull request with the documents. It works in its
  own worktree (`~/.local/share/senior-mode/worktrees/<repo>/frame-<slug>`) and branch `docs/<slug>` from `origin/main` (`senior-mode frame start`), so framings
  can run in parallel; the spec is named after its issue (`docs/specs/<issue>-<slug>.md`) and ADR
  numbers come from `origin/main`. Ends with at most five lines, then proactive suggestions.
- **Limits.** A size S needs no spec: `frame` creates its issue (or takes the existing one), puts it
  on the board with Size S, checks its criteria are testable and marks it Ready, then delivers it in
  the same session through the steps of `go` (red test, pull request, review, merge on a clear yes).
  In a headless session it stops at Ready, so `go` and the daemon deliver it. An M or L ends with Ready
  tickets, then "on enchaîne ?"; with the daemon running, Claude says the daemon takes them. If the default branch has commits origin lacks, it
  stops and asks you to push them first. During framing, edits outside `docs/` are
  denied, subagents included. Re-running is safe: an open issue with the same title is reused.
  Tickets stay in Backlog until the documents pull request is merged and the spec accepted.

## `go`

State: **Available.**

```
/senior-mode:go [#issue | auto]
```

- **Purpose.** Move the project forward, whatever its state. In a repository not adopted yet it runs
  `setup` first. When `serve` runs in this repository (`status` says "Daemon: serve is running"), the
  daemon delivers: `go` says what needs you and where to watch, and stops. `go auto` starts the
  daemon (`senior-mode serve --install`) after you confirm `autonomy.parallel` and `autonomy.merge`.
  Otherwise, the daily session: a short state of the board, open pull requests needing a human,
  then the top Ready ticket delivered with you in the loop (tests first, commits, pull request).
- **Runs.** `senior-mode status`; the pull requests that need you, each offered for review or merge;
  `senior-mode pick --max 1`, which you confirm (or `/senior-mode:go #42` for a Ready ticket of your
  choice); `senior-mode start`, which makes the worktree and branch and moves the ticket to In
  progress; then the `test-author`, the `implementer`, `senior-mode check`, the pull request with
  `Closes #n`, and a fresh-context review, as in [A typical day](a-typical-day.md) steps 3 to 7.
- **Asks.** To take the ticket it picked, and whether to merge once the review is done. It never
  merges without your explicit yes, and a `needs-human` pull request is yours to merge. After a
  merge it runs the `docs` skill and offers the next ticket.
- Ask "go", "suivant", "on enchaîne" or "prochain ticket", or type `/senior-mode:go`.

## `next` (former name of `go`)

Kept for one release, then removed: it says it is now `go` and runs it.

## `status`

State: **Available.**

- **Purpose.** A cheap, plain-language dashboard: done since last time, in progress, in review,
  blocked or missing information, waiting for a human (`needs-human` pull requests, failing
  statuses), the next Ready tickets, and the release state. One GitHub call. Each ticket In progress
  shows the path of its worktree.
- **Asks.** Nothing. Ask "where are we?" or "état", or type `/senior-mode:status`.
- **Produces.** A summary in the `language` of your config, with what needs you first. Ask for "the
  week for the client" and it runs `senior-mode status --since 7d`, a digest without jargon.
- **Daemon and retro.** When `serve` runs in this repository, a line says so with its pid (`serve` in
  `--json`). The first status starts a weekly clock; a week after the last `retro` (or that first
  status), "Retro due" asks for one and the skill offers it (`retro` in `--json`, with `lastDays`
  and `due`). Both are read from `.git/senior-mode/`, on this machine.
- **Live view.** `senior-mode status --watch` in a terminal or tmux pane redraws every 30 seconds.
- **Spec drift.** A "Spec drift" section (and `specDrift` in `--json`) lists, for each spec of `docs/specs/` with `status: accepted`, the commits that touched its `paths` since the spec file last changed and carry no `Spec-Unchanged: <reason>` line, in their message or in the body of a pull request they belong to (the pull requests GitHub associates with the commit, whatever the merge method and the subject; a commit with no pull request is listed). Only the first-parent history counts, so a merge is one entry. The pull requests are read in batched GitHub calls (50 commits each), and only for commits that need it. Offline, or without `gh`, the section is skipped and `Spec drift: not checked` says why (`specDriftNote` in `--json`). Nothing is listed when there is no accepted spec or no drift.
- **Health.** `senior-mode status --publish` posts the board's health (on track, at risk, off track, with the counts, the tickets that need a human, failing pull requests and drift) as a Project status update; it cannot be combined with `--watch`. `senior-mode retro` posts it on each pass.
- **Cycle.** `setup github` adds an Iteration field (`board.iterationDays` days, default 14) and Start and End dates; `start` sets Start and the current iteration, a merge sets End. `run` archives items Done for more than `board.archiveAfterDays` days (default 14); archived items stay in `retro`. `senior-mode retro --iteration [<name>]` reviews one iteration (the current one by default).
- Only the plain run moves the "since last time" mark (kept in `.claude/senior-mode/`, ignored by git);
  `--since`, `--json` and `--watch` leave it alone.

### Status line

`/senior-mode:setup` offers a line at the bottom of Claude Code: the ticket of your branch, the last
check recorded for it (`check ok`, `check FAILED`, `check stale` after an edit) and `run in progress`.
It is offline and instant. To add it yourself, run `senior-mode setup statusline`: it writes a
`statusLine` command to `.claude/settings.json` that finds the plugin at each run, so plugin updates
do not break it. The status line is set for this project only: it replaces your personal one in that project; one the project
already has is kept. If the plugin is loaded with `--plugin-dir`, the line stays empty.

## `run` (former skill; the batch command stays)

The `/senior-mode:run` skill is kept for one release: it says it is now `/senior-mode:go auto` (the
daemon) and runs that. The `senior-mode run` command below stays, for a bounded batch without the daemon.

- **Purpose.** Deliver up to N Ready tickets (`autonomy.maxTickets`, default 3) without you, P at a
  time (`autonomy.parallel`, default 1), and report in plain language: merged, merged but left off Done, waiting for a human,
  failed and why, not started.
- **Asks you.** To confirm the tickets, N, P and whether the run merges.
- **How.** `senior-mode run [--max N] [--parallel P]` starts one headless `claude -p` session per
  ticket, in the worktree `senior-mode start` opens for it (`~/.local/share/senior-mode/worktrees/<repo>/<n>`, branch `<type>/<n>-<slug>`)
  and, when tmux is installed, in a window of `tmux attach -t senior-mode-run`. A ticket that fails on
  Sonnet is retried once on Opus (`autonomy.escalate`). Logs stay in `.git/senior-mode/runs/`, with one
  `<n>.json` per ticket that says how it ended (`delivered`, `outgrown` or `failed`, whether it went
  to Opus, why, when). A `type:spike` ticket with a `Timebox: <N>m` or `<N>h` line is stopped when that time is up
  (before `autonomy.sessionTimeout`, if it is shorter): the session is killed, the notes it left under `docs/spikes/`
  go in a comment, the ticket gets `needs-human` and is recorded as `delivered` with the reason. It is no failure and
  does not count for the circuit breaker. A token budget is written in the ticket and the prompt, not enforced.
- **Alerts.** First, it files one `security` issue for each open high or critical Dependabot alert and
  each open secret-scanning alert (once: the second pass finds them), then picks tickets.
- **Merging** is off by default: the run stops at pull requests with `senior-mode/ci`,
  `senior-mode/review` and `senior-mode/security` set. With `autonomy.merge: true` it merges what is green, not `needs-human`,
  on a repository with server-side protection or `github.protection: "local"` (senior-mode gates the merge). See [Autonomy](autonomy.md#run).
- **Needs** `claude` on PATH or in `~/.local/bin`, `flock` and a user that is not root. In a workspace Claude
  Code does not trust yet, headless sessions ignore the project's permissions: open the folder once
  interactively and accept the trust prompt. See [Sessions without a human](autonomy.md#sessions-without-a-human).

## `retro`

State: **Available.**

- **Purpose.** The weekly learning step: what was done and how long it took, what needed you and why,
  what failed, was reopened or outgrew its size. Then at most three changes to the way of working.
- **Asks.** Nothing to start; type `/senior-mode:retro`, or ask for "a retro", "rétro" or "bilan de
  la semaine". It then asks which of its proposals to create.
- **Produces.** A summary in the `language` of your config, and up to three issue drafts (a
  `CLAUDE.md` pitfall, a protected glob, a check, a ticket split rule), each with the tickets and pull
  requests that justify it. Nothing is created or edited until you say yes.
- **Data.** First it files the open high or critical Dependabot and secret-scanning alerts as issues,
  as `run` does. Then, from GitHub (two calls) and from this machine: the results of `senior-mode check` and, when
  `run` has written them, its outcomes in `.git/senior-mode/runs/`. Without them, the runs section says
  so. `senior-mode retro --since 14d` widens the period.
- **Token use.** Each session `run` or `serve` starts appends its tokens (input, output, cache read, cache
  write) per model to `.git/senior-mode/usage.jsonl`. `retro` shows them per ticket and role (ticket,
  test-author, reviewer, integrator, and `run docs` for the docs session), with an estimated USD
  equivalent at the public API prices and a total; `--json` carries the same data under `usage`. The
  prices live in `bin/lib/prices.json`, with their date and source; a model it does not list shows its
  tokens and "no price". Under a subscription, the dollar figure only compares tickets, it is not a bill.

## The `senior-mode` script

The plugin puts a `senior-mode` script on the PATH of Claude's Bash tool. Claude uses it; you can
too, with `!` at the Claude Code prompt. All of it is available today.

| Command | What it does |
|---|---|
| `senior-mode setup github [--ci local\|actions\|existing] [--migrate\|--upgrade] [--dry-run]` | The GitHub side of setup (`--upgrade` adds to the board of the config every field and single-select option the template has and the board lacks, such as Severity, Paths, Iteration, Start and End, or the options a pre-0.5 Status lacks, and lists them; values, options and items already there are untouched (an option matches by name in any case or by the alias Todo for Backlog), the ids are cached in the config, and a rerun adds nothing; it touches only the Project, never the ruleset, labels, repository settings or workflows, so it is safe with `github.requiredChecks: false`; `--dry-run` lists and changes nothing; not with `--migrate` or `--ci`; `--migrate` moves an existing board to a Project built from the template: `--dry-run` prints the mapping of items, fields and options and changes nothing; without it, a Project is copied from the template, every item is added with its field values, a field or single-select option the template lacks is created as is and listed, the new Project is linked and recorded in the config, and the old one is closed, never deleted, with the command that reopens it; a rerun after an interruption adds no item twice; iteration fields have no API and are listed as not migrated): Project (copied from the template when there is none) with its README, fields, labels (not the ones `workflow.labels` maps to the project's own), merge settings (the project's `workflow.merge` is enabled and the other methods kept, instead of rebase only), workflows (`--ci existing`: none disabled, no `senior-mode.yml`), ruleset (the method of `workflow.merge`, no `required_linear_history` unless rebase, and with `existing` the contexts of `workflow.ci.required` next to the three senior-mode ones; still the default branch only), CODEOWNERS for the protected zones, Dependabot alerts, secret scanning and push protection (no Dependabot security updates, no `.github/dependabot.yml`) |
| `senior-mode setup detect [--json]` | What setup reads before it asks: the preset (and framework, TypeScript), whether the repository is public or private, the owner type and plan, whether GitHub offers rulesets there, and the language of the project or personal `CLAUDE.md` (else the locale). Changes nothing; GitHub unreachable reads as `unknown` |
| `senior-mode setup answers [--strictness strict\|fast] [--language en\|fr] [--autonomy ask\|alone] [--lsp yes\|no] [--dry-run]` | The three setup answers, written to `.claude/senior-mode.json`; an answer left out keeps the stored value, else takes the recommended one (`strict`, the detected language, `ask`). Prints one summary first: what was detected, what each answer changes, the defaults that apply. `--strictness fast` sets `process.profile` and a `review` lift in `process.lifts`, and writes an accepted ADR `docs/adr/NNNN-lift-independent-review.md` (kept when the repository already has an accepted lift): commit it to the default branch, the daemon reads that branch; `strict` removes both. `--autonomy alone` sets `autonomy.merge` to `true`, `ask` to `false`. `--lsp yes\|no` records the answer to the language server proposal of `setup repo` as `lsp` (`true` or `false`); left out, the key is untouched. `--dry-run` writes nothing |
| `senior-mode setup repo [--command <name>=<cmd>]... [--dry-run] [--adopt]` | The repository side of setup, after reading the project's [workflow](configuration.md#following-the-projects-workflow) (branch model, commit and pull request format, merge method, CI jobs, labels, tracker, evergreen or legacy; a question it cannot ask takes the recommended answer and is printed `assumed`): `--dry-run` prints what it found and would write and changes nothing, `--adopt` opens it as the pull request `docs: adopt senior-mode`; a `commit-msg` hook of the project's own is kept and ours is installed as `.githooks/commit-subjects`; `--command` stores a lint, typecheck, test, build (or, for node, e2e) command and its check, or `install=<cmd>`, the command `start` runs in a new worktree; for a node, python, go or rust project it prints the stack's language server (`typescript-language-server`, `pyright`, `gopls`, `rust-analyzer`) and the `claude plugin install <name>-lsp@claude-plugins-official` command that enables it in Claude Code, and installs nothing; it prints nothing for the generic preset, or once `lsp` is in the config; it proposes adding `docs/vision.md` to `protected` while no glob covers it, so that agent sessions cannot edit the vision |
| `senior-mode check [--pre-push\|--ci-only\|--changed\|--update-baseline]` | Runs the secret scan of the branch's added lines, the [dependency audit](configuration.md#dependency-audit) of the lockfile (off with `audit: false`), the registry lookup of the [new dependencies](configuration.md#new-dependencies), the `config` step ([`config validate`](#the-senior-mode-script)), the context hygiene (fails on a tracked `CLAUDE.md` over [`context.claudeMdLines`](configuration.md#keys-the-plugin-reads-today) lines, a `SKILL.md` over 3072 bytes, an ADR whose front-matter `paths` is not a list of strings; warns on a path a `CLAUDE.md` cites between backticks that no longer exists), then the check list, each check timed (a failed check also keeps its full output in `senior-mode/check-logs` of the git directory, the 20 latest logs, and prints the path under its last lines); then a `warn  spec drift` line per accepted spec whose `paths` changed with no `Spec-Unchanged:` line (a warning: it never changes the exit code, see [`status`](#status)); then, when `docs/vision.md` exists, the `vision` check, which fails without a `## Goals` section whose list items start with unique ids `G1`, `G2`..., without a `## Non-goals` section, or past `vision.maxLines` lines (nothing is reported without the file); then, when `docs/knowledge/` exists, the `knowledge` check, which fails, naming the file and the key, on a [note](configuration.md#knowledge-notes) with a file name that is not a kebab-case slug, a missing `paths` (a non-empty list of globs), `verified` (`YYYY-MM-DD`, not in the future), `origin` (`#<n>`, `retro` or a `docs/spikes/` path) or `kind` (`pitfall`, `convention`, `howto` or `context`), or a body over `knowledge.maxLines` lines (nothing is reported without the directory); then, when `architecture.rules` is set, the `architecture` check, which fails on a violation of a [rule](configuration.md#architecture-rules) outside `.claude/architecture-baseline.json`, naming the rule, the file and the line, and on a rule with no `id`, an unknown kind or a missing part (a configuration error; a baseline entry that no longer violates is a warning); then a `warn  suppression added: <file>:<line>: <text>` line per line the branch adds that silences a check or skips a test (`eslint-disable`, `@ts-ignore`, `@ts-expect-error`, `# noqa`, `# type: ignore`, `#[allow(`, `//nolint`, `.skip(`, `xit(`, `xdescribe(`, `@pytest.mark.skip`, `t.Skip(`; Markdown left out), a warning too: the review judges it, a reason written beside it makes it legitimate; prints a `warn  test case with no assertion: <file>:<line>: <text>` line per test case the branch adds with no assertion (per preset: node `expect`/`assert`, python `assert`/`pytest.raises`, go `t.Error`/`t.Fatal`/`assert.`/`require.`, rust `assert*!`/`panic!`/`unwrap`; none for generic), an error (`FAIL  assertion-free tests`) in a `run` or `serve` session (`SENIOR_MODE_RUN=1`); `--update-baseline` runs nothing else: it rewrites `.claude/architecture-baseline.json` without the violations that are fixed (and lowers an entry to what is left) and refuses, with exit 1, to add one; `--changed` runs each check that has a `changed` variant (`checks[].changed`, a command with a `{files}` placeholder, or the [preset's](configuration.md#changed-checks)) on the files the branch changed against the default branch, committed or not, and every other check in full; each line says which (`ok    lint [changed: 3 files]`, `ok    tests [full]`), a variant with no file to take is skipped, the exit status is the checks', and the run is not recorded for `publish`; `--pre-push` and `publish` refuse `--changed`; on a clean tree, records the result for the current commit; a node project without `node_modules` fails first with `dependencies not installed: run <cmd>`; `--pre-push` (the hook's) reads the pushed refs, hands the changed paths to the checks and does not record the run; `--ci-only` (`ci.mode` `existing`) does not run the checks a job of the project's CI covers and reads that job on the commit instead: `ok`, `wait <job>` (exit status 2 while it runs or has not started) or `FAIL <job>: <run URL>` |
| `senior-mode setup remove [--apply]` | Takes senior-mode out of the repository. A dry run by default: it lists what it would remove and changes nothing. `--apply` turns the workflows setup disabled (`ci.mode local`) back on, opens a pull request (branch `chore/remove-senior-mode`, made in a temporary worktree of the default branch, so your checkout is not touched) that removes the git hooks it installed, `.claude/senior-mode.json`, the Principles block of `CLAUDE.md`, its block of `.github/CODEOWNERS`, the senior-mode permissions and status line of `.claude/settings.json`, its workflow, and the pull request template, issue forms and `docs/architecture.md` while they are still its templates (an edited one is kept, and so are `release-please-config.json` and its manifest); then, once the pull request is open so that the ruleset cannot hold it, it deletes the `senior-mode` ruleset and the labels it created that still have its description and that no issue or pull request uses, and unsets `core.hooksPath` of this checkout when `.githooks` holds nothing of yours. The Project and the issues are kept (history). Every step is idempotent: a rerun after a partial removal finishes what is left, and says so when nothing is. The `serve` service and the `schedule` entry of this machine are stopped with `serve --uninstall` and `schedule remove` |
| `senior-mode publish [commit]` | Sends the recorded result to GitHub as `senior-mode/ci` (the commit must be pushed; with `ci.mode` `existing` the result also holds the project's CI jobs as they are now: a failed one fails it with the URL of its run, a running or missing one leaves it pending), and sets `senior-mode/security`: success "not required: no protected zone, not L", else pending until the `security` agent has judged (see [Autonomy](autonomy.md#required-statuses)) |
| `senior-mode release [--dry-run]` | Runs release-please 17.11.2 locally: tags a merged release PR, opens or updates the next one |
| `senior-mode issue create --title ... --body-file ... --size ... --priority ...` | Creates a ticket with board fields, and optionally `--status`, `--milestone`, `--type` (`feature`, `bug`, `task`, `chore` or `spike`; a spike needs `--timebox <N>m|<N>h|<N>[k] tokens`, which other types refuse and which adds a `Timebox:` line to the body), `--paths <globs>` (comma-separated globs the ticket touches, written to the board field Paths; refused when the config has no Paths field), `--blocked-by`, `--parent`, `--severity critical\|high\|moderate\|low` (sets the Severity field and the `security` label; critical implies P0 and high P1, the stricter of that and `--priority` wins, and `--priority` may then be left out); `--kind`, `--path` and `--rule` (a risk outside the ticket, with `--severity`) add the line `security-id: <sha256 of the three>` to the body and, when an open `security` issue already carries it, print that issue instead of filing another (a title match alone no longer reuses an issue then; a newline in the three is refused); a critical one in a public repository also opens a draft security advisory holding `--details-file <file\|->` (required there, never put in the issue), a private repository gets a message instead; `--no-advisory` (not with `--details-file`) skips the advisory and needs no details, for a risk that is no flaw in the project's own code, as the alerts GitHub raises that `run` and `retro` file; reuses an open issue with the same title and replaces its body; an issue created in an unattended session (`SENIOR_MODE_RUN`) ends with the line `filed-by: agent`, which `ready` reads |
| `senior-mode pick [--json] [--max N]` | The Ready tickets in delivery order: Priority, a critical Severity first within a Priority (a tie-break only: a critical ticket moved by hand to P1 still sorts after a P0), then milestone due date; leaves out size L, blocked tickets and `needs-info`. `--json` adds each ticket's `paths` (the board field, as a list) and `batch`: the numbers of the Ready S tickets delivered together with it, or `null`. Ready S tickets whose Paths overlap are batched, at most 3 and at most `limits.prLines` / 50 (an S is about 50 lines); an M or a ticket without Paths never is; the text output ends such lines with `[batch #a #b]`. `--max` cuts the list before the batches are formed. `run` and `serve` start a batch as one session and one pull request (see [Run](autonomy.md#run)) |
| `senior-mode start <issue>` | Creates the worktree (`${XDG_DATA_HOME:-~/.local/share}/senior-mode/worktrees/<repo>/<issue>`, `<repo>` being the checkout's name and a short hash of its path; never beside the repository; a ticket started earlier beside it or under `.git/senior-mode/worktrees` keeps its worktree, and `start` says where it is) and the branch `<type>/<issue>-<slug>` for a ticket (a `type:spike` ticket gets a `chore/` branch), from the default branch (with a detected [workflow](configuration.md#following-the-projects-workflow): the project's branch pattern, from its integration branch, or from the release line of a `Base:` line; `base <branch>` says where the pull request goes; a ticket whose base is no release line is `needs-human`, one missing the tracker key the pattern needs is `needs-info`), installs the dependencies with the `install` command of the config (`npm ci`, `pnpm install --frozen-lockfile`...), and sets Status `In progress`; safe to rerun |
| `senior-mode run [--max N] [--parallel P]` | A bounded autonomous batch without the daemon: one headless session per ticket, then a plain report |
| `senior-mode schedule install [--at HH:MM] [--max N]` | Runs `senior-mode run` every day on this machine, as a systemd user timer or a tagged crontab line ([scheduled runs](autonomy.md#scheduled-runs)) |
| `senior-mode schedule remove` | Disables and deletes the timer, or the tagged crontab line |
| `senior-mode schedule status` | The next trigger and the result of the last scheduled run |
| `senior-mode serve` | The daemon of [spec 131](../specs/131-autonomy.md) (ADR 0017): every `serve.interval` seconds (60) it takes the Ready tickets in `pick` order and starts one headless session each, in the worktree `start` opens, as `run` does (same prompt, outcome line, Opus retry, `needs-human` and Backlog handling, `autonomy.merge` bounds), then keeps polling; it never stops on its own. It stays within the ceilings: `autonomy.parallel` sessions at once, `autonomy.ticketsPerHour` tickets begun (6) and `autonomy.sessionsPerHour` sessions of any role (6 per slot) in any 60 minutes, nothing launched while the load average is over the CPU count or less than `autonomy.minMemoryMB` (1024) is available (the launch waits for the next poll). A session that ends on the subscription usage limit without an outcome is no failure: its ticket goes back to Ready and nothing launches until the reset time in the message (one hour when it gives none). Every session end is classified: a *transient* one (network or DNS such as `EAI_AGAIN`, API 5xx, 529 or overloaded, a Claude startup error such as "still loading your organization's settings", a `gh` or `git` call that timed out) is resumed on the same model after a backoff of 30 seconds doubled at each end in a row (15 minutes at most), with nothing launched meanwhile, and counts as no failure, no escalation and no launch against `autonomy.sessionsPerHour` when it died at once; an *environment* one (disk full, `gh` or Claude not signed in, dependencies that cannot be installed, the base branch red, or a session that says `failed: environment: ...`) pauses the whole daemon with the diagnosis in the log, the webhook and a Project status update, probes again after 1, 2, 4... minutes (30 at most) and resumes by itself when the probe is green; any other end is the ticket's (retry, Opus, `needs-human`). After `autonomy.maxConsecutiveFailures` ticket failures in a row it pauses for `serve.breakerCooldown` seconds (300), doubled at each pause that no delivery separates from the last (a day at most), and goes on polling. Every `gh` call of the daemon is cut after `SENIOR_MODE_GH_TIMEOUT` seconds (60) and its `git` network calls after `SENIOR_MODE_GIT_TIMEOUT` (120): a cut is a transient failure, tried again at the next poll. `TERM` or `INT` stop the launching at once, let the running sessions finish for up to `serve.grace` seconds (600), then kill them and label their tickets `needs-human`. One serve per repository; its state (sessions, outcomes `<n>.json`, `launches`, `paused`, `limit-until`, `serve.pid`) is in `.git/senior-mode/serve/`. It reads the config at start. Each poll also does the rest of the flow ([Serve](autonomy.md#session-roles)): a ticket In review whose `senior-mode/ci` is `success` and that has no `senior-mode/review` gets a reviewer session (a model other than the implementer's, Opus unless the ticket ended on Opus: `review.crossModel`; role `reviewer`, in a detached worktree of the head; the model opens the description of `senior-mode/review`); a review of changes requested sends the ticket session back for up to 2 fix rounds, then `needs-human`; an M ticket gets a `test-author` session before its ticket session; and the integrator pass merges at most one pull request per poll (`autonomy.merge`, on by default under `serve`, same bounds as `run`, `--match-head-commit`, `--auto` when the repository allows auto-merge), rebases one that is behind, and starts an Opus integrator session on a `-r2` branch for a conflict. A ticket session under `serve` never merges its own pull request. `SENIOR_MODE_SERVE_ONCE=1` polls once, waits for its sessions and exits; `SENIOR_MODE_NOW` is its clock (epoch seconds) |
| `senior-mode serve --install` | Writes and starts the systemd user service `senior-mode-serve.service` that runs `senior-mode serve` in this repository: `Restart=on-failure`, `KillMode=mixed` (`systemctl --user stop` sends `TERM` to serve alone, which lets the sessions finish within `serve.grace`), `TimeoutStopSec` of the grace plus a minute. It needs a user systemd and is named once per machine: another repository must `--uninstall` it first. `loginctl enable-linger` keeps it alive after logout; logs: `journalctl --user -u senior-mode-serve` |
| `senior-mode serve --uninstall` | Disables and deletes the service |
| `senior-mode serve --resume` | Lifts the circuit breaker's pause and an environment pause now, instead of waiting for `serve.breakerCooldown` or for a green probe |
| `senior-mode e2e-lock -- <command>` | Runs the command once one of `e2e.slots` machine-wide slots is free; `check` runs the check named `e2e` through it (with a `TMPDIR` of its own, like every check: two `check` runs at once share no temp path) |
| `senior-mode slot -- <command>` | Runs the command in a [slot](autonomy.md#session-slots) of its own (`SENIOR_MODE_SLOT`, from 1 to `autonomy.parallel`) with the `KEY=VALUE` lines of the `slot` command of the config exported; `run` starts every ticket session this way |
| `senior-mode ready [--pr <n>] [--dry-run]` | Makes tickets Ready [by rule](autonomy.md#ready-by-rule), with no human step: the Backlog tickets that the merged framing pull request `n` (branch `docs/...`) names, or without `--pr` those an agent filed. A ticket with acceptance criteria, Size, Priority and Paths becomes Ready; any other gets `needs-human` and a comment saying what is missing. `--dry-run` only prints what would happen. `--pr <n>` on an open pull request that is no framing one says whether it is [ready to merge](autonomy.md#ready-pull-request): one commit per closed ticket for a batch, the changed lines within the size budget (`limits.diffLines`) of its tickets, and a "Self-review" table in its body with a row `#<ticket>.<k>` (or `<k>` for a single ticket) and its evidence (a test name or a command and its result) for each acceptance criterion of each ticket (the top-level bullets under the issue's "Acceptance criteria" heading; the missing ones are named); and, for a `type:spike` ticket, only files under `docs/`; exit 1 when it is not. `run` and `serve` apply the same rules before a merge |
| `senior-mode status [--json] [--since <dur>] [--watch [secs]] [--fix]` | The dashboard of `/senior-mode:status`; `--since 7d` for a digest (`m`, `h`, `d`, `w`). `Dependency audit: off` appears when `audit: false` turns it off. A "Decisions" section groups everything that waits for you, each with its kind, its age (since the last activity on GitHub) and the question to answer: tickets with `needs-human`, pull requests with `needs-human` (`pull-request`), tickets in framing (open tickets with `needs-info`) and `framing-draft` pull requests (`framing`); the question is the first line of the last comment when a collaborator wrote it, else a default. They are sorted by Priority, then oldest first; `--json` has the same as `decisions`: `{number, kind, title, age (seconds), question, options, recommended, id, priority}`. Pull requests that fail their checks are listed apart, under "Failing checks". A "Spec drift" section lists the commits under the `paths` of an accepted spec since it last changed, with no `Spec-Unchanged:` line (see [`status`](#status)). A "Board drift" section lists closed tickets not Done, open tickets Done, and tickets In progress or In review with no pull request and no branch; `--fix` sets the closed ones Done and leaves the rest to you (not with `--watch`). A "Hygiene" section lists, each with its reason: open pull requests with no activity for `hygiene.days` days (14); remote branches with no pull request at all (not the default branch, a branch an open pull request targets, or a protected one); open pull requests that a line starting `Supersedes #m` of another one names; tickets In progress with no worktree, no open pull request, no branch (remote or local) and no activity for `hygiene.days` days (the later of the last update of the issue and of its board item: moving a ticket to In progress counts). A `Supersedes #m` line inside a fenced code block does not count. Plain `status` only reports. `--fix` prints the report, then acts only where it is safe: it closes the pull request `#m` with a comment when the superseding one is open, not a draft, not from a fork, and written by the author of `#m` or by someone with write access, and `#m` supersedes nothing itself (two that supersede each other: neither is closed, both are said); it deletes a branch named like a ticket branch (`feat|fix|chore|docs|test|refactor/<issue>-...`) with no pull request, a last commit older than `hygiene.days`, not protected, unmoved since the report and with no commit outside the default branch (names are percent-encoded; all of it read again just before); it moves an orphan ticket back to Ready with a comment after reading the board, the issue, the open pull requests and the branches again (a ticket reported here is not also listed as drift). Everything else is left and said; a stale pull request is never touched. It follows the pages of branches and pull requests |
| `senior-mode clean [--dry-run] [--days N]` | Tidies the repository ([hygiene](autonomy.md#hygiene)): removes the worktrees (wherever they are) and local branches whose pull request is merged or closed on GitHub, or whose ticket is closed with no pull request; the remote branches of a pull request merged or closed more than N days ago; the run directories and probe files under `.git/senior-mode` older than N days; then runs `git worktree prune`. N is `--days`, else `hygiene.days` (14). It lists, and keeps, a worktree with uncommitted changes, a branch with commits on no remote branch and not in the default branch, a ticket In progress, a protected branch, the base of any pull request and any branch that `start`, `frame start` or `run` do not make (`dev`, `release/*`, `docs/next.v2`); the main and the current worktree are never touched. It runs `git fetch --prune origin` first, dry run included (if that fails, "pushed" is unknown and such a branch is kept). `--dry-run` prints what would go and changes nothing. `run` calls it when it starts and ends, `status --fix` after its report |
| `senior-mode retro [--json] [--since <dur>]` | The facts of `/senior-mode:retro` for the last 7 days or `--since`: done, cycle time, pull requests that needed a human, runs, reopened tickets, check failures, sizes (per size: the median and spread of cycle hours, changed lines and tokens, the tickets far outside it, and a recalibration hint when most of three or more exceed its line budget), token use and estimated cost per ticket and role, and the same read-only "Repository hygiene" list as `status` |
| `senior-mode statusline` | One offline line for Claude Code's status line (ticket, last check, run) |
| `senior-mode setup statusline` | Writes the status line to the project's `.claude/settings.json` |
| `senior-mode item set <issue> <field> <option>...` | Sets board fields of a ticket, for example `Status Ready`; a field cached without options (`Paths`) takes text: `Paths "a/**,b.sh"` |
| `senior-mode item get <issue> [field]` | Reads the board fields of a ticket in one call: the value of `field`, or every field set (`#42 Status = Ready`) |
| `senior-mode config get <key>` | Prints a config value, with defaults (see [Configuration](configuration.md)) |
| `senior-mode config explain <key>` | Prints the value of a key, the [layer](configuration.md#layers-overrides-and-process-profiles) that won (defaults, profile, organization, repository, local) and the values it shadows |
| `senior-mode override list` | Lists the project's [overrides](configuration.md#overrides) of the plugin's skills, agents and templates, replace or append |
| `senior-mode override show <file>` | Prints the text in force of a plugin file (`skills/review/SKILL.md`): the plugin's own with the project's override |
| `senior-mode config validate [--json]` | Reads `.claude/senior-mode.json` against [its schema](configuration.md#validation-and-the-json-schema): an unknown key (with the closest known one), a value out of its domain or of the wrong type is an `error:` line and exit 1; a deprecated key or value is a `warning:` line. `--json` prints `{valid, findings: [{level, path, message}]}`. `check` runs it as its `config` step |
| `senior-mode doctor [--json]` | Diagnoses the installation, one line per check (`ok`, `warn`, `FAIL`) and, for each failure, the command that fixes it: `git`, `jq`, `gh` and `claude` on the `PATH` with their versions, `gh` logged in with the `repo` and `project` scopes, Claude Code logged in, the `pre-push` and `commit-msg` hooks, the configuration read against [its schema](configuration.md#validation-and-the-json-schema), the board fields of the config and the ruleset that `github.protection` announces. A "Customization" section lists what departs from the defaults: the [profile](configuration.md#process-profiles), the lifted gates, the [overrides](configuration.md#overrides) and the values each [layer](configuration.md#layers) sets. Exit 1 when a check fails, 0 otherwise (warnings do not fail). `--json` prints `{ok, checks: [{level, name, message, fix?}], customization}` |
| `senior-mode protected [--base <ref>]` | Lists the files changed on the branch that match a `protected` glob (exit 0), or nothing (exit 1); used by the reviewer |
| `senior-mode red-tests record <issue>` | Records the files the `test-author` session committed on the ticket branch since the default branch, in `.git/senior-mode/runs/<issue>/red-tests` (one path per line), for the [guard](autonomy.md#session-roles) to keep read-only for the ticket session. Written once, so run it between the test-author and the implementer sessions; fails when the branch holds no commit yet |
| `senior-mode red-tests verify <issue>` | The proof of a `type:feature` or `type:bug` ticket whose tests were not written by a `test-author` session: the test files the branch adds or changes since the default branch (per preset) are carried to a worktree at the merge base, where the test command (`commands.test`, else the check named `test`) must fail, and on the head it must pass; they are then listed in `.git/senior-mode/runs/<issue>/red-verified`, the record `run` and `serve` look for next to `red-tests` ([ready pull request](autonomy.md#ready-pull-request)). Unlike `red-tests`, it makes no file read-only |
| `senior-mode context` | Prints the session greeting, then the goals (`G1`...) and non-goals of `docs/vision.md` when it exists (the stable start of the briefing), then the current ticket (used by the `SessionStart` hook) |
| `senior-mode frame start <idea>` | Makes the worktree `~/.local/share/senior-mode/worktrees/<repo>/frame-<slug>` (a framing opened elsewhere earlier is reused) and the branch `docs/<slug>` from `origin/main`; refuses when the default branch is ahead of origin |
| `senior-mode frame decide <issue> <question> <answer>` | Appends `- <date> #<issue>: <question> -> <answer>` to `docs/decisions.md` of the repository it runs in (the file is created with its title); a line already there is not added again; `frame` and `grill` call it for each answer, an assumed one ending with `(assumed)` |
| `senior-mode frame end` | Ends every framing session in the repository, so edits outside `docs/` are allowed again |

GitHub calls that fail for a passing reason (timeouts, server errors, rate limits) are retried up to
three times.
