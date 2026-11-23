# Commands

Every `/senior-mode:` command, what it asks you and what it produces, plus the `senior-mode` script.

Commands run only when you type them. The design is in [spec §7](../specs/0001-senior-mode.md#7-commands).

## Overview

| Command | Purpose | State |
|---|---|---|
| `/senior-mode:setup` | Adopt a repository, or repair it | Available |
| `/senior-mode:frame` | Turn an idea into a spec, ADRs and tickets | Available |
| `/senior-mode:next` | Daily session: deliver the top Ready ticket with you | Available |
| `/senior-mode:status` | Plain-language dashboard | Available |
| `/senior-mode:run` | Deliver up to N Ready tickets on its own | Available |
| `/senior-mode:retro` | Weekly review of the board and the process | Available |

## `setup`

State: **Available.**

- **Purpose.** Adopt a repository, new or existing. Safe to re-run: it repairs, never duplicates.
- **Asks you.** Whether to create a GitHub repository if there is none (private by default); to run
  `gh auth refresh -s project` if the scope is missing; where checks run (`local` or `actions`);
  your yes to the list of changes; for a stack without a `package.json`, how to lint, typecheck,
  test and build; your yes before adding a missing linter or test runner.
- **Produces.** A Project board with `Status`, `Priority`, `Size`, `Severity` and the text field `Paths`; labels; rebase-only merges;
  the `senior-mode` ruleset; `.github/CODEOWNERS` for the protected zones; Dependabot alerts, secret scanning and push protection (where the plan allows); `.claude/senior-mode.json`; git hooks; `CLAUDE.md` Principles; PR and
  issue templates; permissions; release-please config; in `actions` mode, a workflow. Ends with a
  plain summary and the Project URL.

Details: [Getting started](getting-started.md#adopt-a-repository).

## `frame`

State: **Available.**

```
/senior-mode:frame <the idea, in a sentence or two>
```

- **Purpose.** Turn an idea into decisions, a spec, ADRs and Ready tickets. Its description names
  "frame", "let's frame" and "cadrons"; typing the command is the sure way to start it.
- **Asks you.** Rounds of 3 to 4 questions, recommended option first, only what the repository and
  GitHub cannot answer. Then whether you accept the spec and ADRs.
- **Produces.** A spec in `docs/specs/` (light for M, full for L), ADRs in `docs/adr/`, tickets on
  the board as vertical slices (size, priority, milestone, Given/When/Then criteria, test seams,
  blockers; an epic with sub-issues for L), and a pull request with the documents. It works in its
  own worktree (`~/.local/share/senior-mode/worktrees/<repo>/frame-<slug>`) and branch `docs/<slug>` from `origin/main` (`senior-mode frame start`), so framings
  can run in parallel; the spec is named after its issue (`docs/specs/<issue>-<slug>.md`) and ADR
  numbers come from `origin/main`. Ends with at most five lines, then proactive suggestions.
- **Limits.** A size S stops at once: it needs no framing. When the idea is an existing issue, `frame` first
  puts it on the board with Size S, checks its criteria are testable and marks it Ready; in a headless
  session a new S idea first becomes that issue, so `next` and `run` can deliver it. If the default branch has commits origin lacks, it
  stops and asks you to push them first. During framing, edits outside `docs/` are
  denied, subagents included. Re-running is safe: an open issue with the same title is reused.
  Tickets stay in Backlog until the documents pull request is merged and the spec accepted.

## `next`

State: **Available.**

- **Purpose.** The daily session: a short state of the board, open pull requests needing a human,
  then the top Ready ticket delivered with you in the loop (tests first, commits, pull request).
- **Runs.** `senior-mode status`; the pull requests that need you, each offered for review or merge;
  `senior-mode pick --max 1`, which you confirm (or `/senior-mode:next #42` for a Ready ticket of your
  choice); `senior-mode start`, which makes the worktree and branch and moves the ticket to In
  progress; then the `test-author`, the `implementer`, `senior-mode check`, the pull request with
  `Closes #n`, and a fresh-context review, as in [A typical day](a-typical-day.md) steps 3 to 7.
- **Asks.** To take the ticket it picked, and whether to merge once the review is done. It never
  merges without your explicit yes, and a `needs-human` pull request is yours to merge. After a
  merge it runs the `docs` skill and offers the next ticket.
- Ask "suivant", "on enchaîne" or "prochain ticket", or type `/senior-mode:next`.

## `status`

State: **Available.**

- **Purpose.** A cheap, plain-language dashboard: done since last time, in progress, in review,
  blocked or missing information, waiting for a human (`needs-human` pull requests, failing
  statuses), the next Ready tickets, and the release state. One GitHub call. Each ticket In progress
  shows the path of its worktree.
- **Asks.** Nothing. Ask "where are we?" or "état", or type `/senior-mode:status`.
- **Produces.** A summary in the `language` of your config, with what needs you first. Ask for "the
  week for the client" and it runs `senior-mode status --since 7d`, a digest without jargon.
- **Live view.** `senior-mode status --watch` in a terminal or tmux pane redraws every 30 seconds.
- Only the plain run moves the "since last time" mark (kept in `.claude/senior-mode/`, ignored by git);
  `--since`, `--json` and `--watch` leave it alone.

### Status line

`/senior-mode:setup` offers a line at the bottom of Claude Code: the ticket of your branch, the last
check recorded for it (`check ok`, `check FAILED`, `check stale` after an edit) and `run in progress`.
It is offline and instant. To add it yourself, run `senior-mode setup statusline`: it writes a
`statusLine` command to `.claude/settings.json` that finds the plugin at each run, so plugin updates
do not break it. The status line is set for this project only: it replaces your personal one in that project; one the project
already has is kept. If the plugin is loaded with `--plugin-dir`, the line stays empty.

## `run`

State: **Available.** Triggers: "run", "lance", "enchaîne en autonomie".

- **Purpose.** Deliver up to N Ready tickets (`autonomy.maxTickets`, default 3) without you, P at a
  time (`autonomy.parallel`, default 1), and report in plain language: merged, merged but left off Done, waiting for a human,
  failed and why, not started.
- **Asks you.** To confirm the tickets, N, P and whether the run merges.
- **How.** `senior-mode run [--max N] [--parallel P]` starts one headless `claude -p` session per
  ticket, in the worktree `senior-mode start` opens for it (`~/.local/share/senior-mode/worktrees/<repo>/<n>`, branch `<type>/<n>-<slug>`)
  and, when tmux is installed, in a window of `tmux attach -t senior-mode-run`. A ticket that fails on
  Sonnet is retried once on Opus (`autonomy.escalate`). Logs stay in `.git/senior-mode/runs/`, with one
  `<n>.json` per ticket that says how it ended (`delivered`, `outgrown` or `failed`, whether it went
  to Opus, why, when).
- **Alerts.** First, it files one `security` issue for each open high or critical Dependabot alert and
  each open secret-scanning alert (once: the second pass finds them), then picks tickets.
- **Merging** is off by default: the run stops at pull requests with `senior-mode/ci`,
  `senior-mode/review` and `senior-mode/security` set. With `autonomy.merge: true` it merges what is green, not `needs-human`,
  on a repository with server-side protection. See [Autonomy](autonomy.md#run).
- **Needs** `claude` on PATH or in `~/.local/bin`, and a user that is not root. In a workspace Claude
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

## The `senior-mode` script

The plugin puts a `senior-mode` script on the PATH of Claude's Bash tool. Claude uses it; you can
too, with `!` at the Claude Code prompt. All of it is available today.

| Command | What it does |
|---|---|
| `senior-mode setup github [--ci local\|actions]` | The GitHub side of setup: Project, fields, labels, merge settings, workflows, ruleset, CODEOWNERS for the protected zones, Dependabot alerts, secret scanning and push protection (no Dependabot security updates, no `.github/dependabot.yml`) |
| `senior-mode setup repo [--command <name>=<cmd>]...` | The repository side of setup; `--command` stores a lint, typecheck, test, build (or, for node, e2e) command and its check, or `install=<cmd>`, the command `start` runs in a new worktree |
| `senior-mode check [--pre-push]` | Runs the secret scan of the branch's added lines, the [dependency audit](configuration.md#dependency-audit) of the lockfile (off with `audit: false`), then the check list, each check timed; on a clean tree, records the result for the current commit; a node project without `node_modules` fails first with `dependencies not installed: run <cmd>`; `--pre-push` (the hook's) reads the pushed refs, hands the changed paths to the checks and does not record the run |
| `senior-mode publish [commit]` | Sends the recorded result to GitHub as `senior-mode/ci` (the commit must be pushed), and sets `senior-mode/security`: success "not required: no protected zone, not L", else pending until the `security` agent has judged (see [Autonomy](autonomy.md#required-statuses)) |
| `senior-mode release [--dry-run]` | Runs release-please 17.11.2 locally: tags a merged release PR, opens or updates the next one |
| `senior-mode issue create --title ... --body-file ... --size ... --priority ...` | Creates a ticket with board fields, and optionally `--status`, `--milestone`, `--type`, `--paths <globs>` (comma-separated globs the ticket touches, written to the board field Paths; refused when the config has no Paths field), `--blocked-by`, `--parent`, `--severity critical\|high\|moderate\|low` (sets the Severity field and the `security` label; critical implies P0 and high P1, the stricter of that and `--priority` wins, and `--priority` may then be left out); `--kind`, `--path` and `--rule` (a risk outside the ticket, with `--severity`) add the line `security-id: <sha256 of the three>` to the body and, when an open `security` issue already carries it, print that issue instead of filing another (a title match alone no longer reuses an issue then; a newline in the three is refused); a critical one in a public repository also opens a draft security advisory holding `--details-file <file\|->` (required there, never put in the issue), a private repository gets a message instead; `--no-advisory` (not with `--details-file`) skips the advisory and needs no details, for a risk that is no flaw in the project's own code, as the alerts GitHub raises that `run` and `retro` file; reuses an open issue with the same title and replaces its body |
| `senior-mode pick [--json] [--max N]` | The Ready tickets in delivery order: Priority, a critical Severity first within a Priority (a tie-break only: a critical ticket moved by hand to P1 still sorts after a P0), then milestone due date; leaves out size L, blocked tickets and `needs-info`. `--json` adds each ticket's `paths` (the board field, as a list) and `batch`: the numbers of the Ready S tickets delivered together with it, or `null`. Ready S tickets whose Paths overlap are batched, at most 3 and at most `limits.prLines` / 50 (an S is about 50 lines); an M or a ticket without Paths never is; the text output ends such lines with `[batch #a #b]`. `--max` cuts the list before the batches are formed. `run` does not start a batch as one session yet (#263) |
| `senior-mode start <issue>` | Creates the worktree (`${XDG_DATA_HOME:-~/.local/share}/senior-mode/worktrees/<repo>/<issue>`, `<repo>` being the checkout's name and a short hash of its path; never beside the repository; a ticket started earlier beside it or under `.git/senior-mode/worktrees` keeps its worktree, and `start` says where it is) and the branch `<type>/<issue>-<slug>` for a ticket, from the default branch, installs the dependencies with the `install` command of the config (`npm ci`, `pnpm install --frozen-lockfile`...), and sets Status `In progress`; safe to rerun |
| `senior-mode run [--max N] [--parallel P]` | The autonomous run of `/senior-mode:run`: one headless session per ticket, then a plain report |
| `senior-mode schedule install [--at HH:MM] [--max N]` | Runs `senior-mode run` every day on this machine, as a systemd user timer or a tagged crontab line ([scheduled runs](autonomy.md#scheduled-runs)) |
| `senior-mode schedule remove` | Disables and deletes the timer, or the tagged crontab line |
| `senior-mode schedule status` | The next trigger and the result of the last scheduled run |
| `senior-mode e2e-lock -- <command>` | Runs the command once one of `e2e.slots` machine-wide slots is free; `check` runs the check named `e2e` through it |
| `senior-mode status [--json] [--since <dur>] [--watch [secs]] [--fix]` | The dashboard of `/senior-mode:status`; `--since 7d` for a digest (`m`, `h`, `d`, `w`). `Dependency audit: off` appears when `audit: false` turns it off. A "Board drift" section lists closed tickets not Done, open tickets Done, and tickets In progress or In review with no pull request and no branch; `--fix` sets the closed ones Done and leaves the rest to you (not with `--watch`). A "Hygiene" section lists, each with its reason: open pull requests with no activity for `hygiene.days` days (14); remote branches with no pull request at all (not the default branch, a branch an open pull request targets, or a protected one); open pull requests that a line starting `Supersedes #m` of another one names; tickets In progress with no worktree, no open pull request, no branch (remote or local) and no activity for `hygiene.days` days (the later of the last update of the issue and of its board item: moving a ticket to In progress counts). A `Supersedes #m` line inside a fenced code block does not count. Plain `status` only reports. `--fix` prints the report, then acts only where it is safe: it closes the pull request `#m` with a comment when the superseding one is open, not a draft, not from a fork, and written by the author of `#m` or by someone with write access, and `#m` supersedes nothing itself (two that supersede each other: neither is closed, both are said); it deletes a branch named like a ticket branch (`feat|fix|chore|docs|test|refactor/<issue>-...`) with no pull request, a last commit older than `hygiene.days`, not protected, unmoved since the report and with no commit outside the default branch (names are percent-encoded; all of it read again just before); it moves an orphan ticket back to Ready with a comment after reading the board, the issue, the open pull requests and the branches again (a ticket reported here is not also listed as drift). Everything else is left and said; a stale pull request is never touched. It follows the pages of branches and pull requests |
| `senior-mode clean [--dry-run] [--days N]` | Tidies the repository ([hygiene](autonomy.md#hygiene)): removes the worktrees (wherever they are) and local branches whose pull request is merged or closed on GitHub, or whose ticket is closed with no pull request; the remote branches of a pull request merged or closed more than N days ago; the run directories and probe files under `.git/senior-mode` older than N days; then runs `git worktree prune`. N is `--days`, else `hygiene.days` (14). It lists, and keeps, a worktree with uncommitted changes, a branch with commits on no remote branch and not in the default branch, a ticket In progress, a protected branch, the base of any pull request and any branch that `start`, `frame start` or `run` do not make (`dev`, `release/*`, `docs/next.v2`); the main and the current worktree are never touched. It runs `git fetch --prune origin` first, dry run included (if that fails, "pushed" is unknown and such a branch is kept). `--dry-run` prints what would go and changes nothing. `run` calls it when it starts and ends, `status --fix` after its report |
| `senior-mode retro [--json] [--since <dur>]` | The facts of `/senior-mode:retro` for the last 7 days or `--since`: done, cycle time, pull requests that needed a human, runs, reopened tickets, check failures, sizes, and the same read-only "Repository hygiene" list as `status` |
| `senior-mode statusline` | One offline line for Claude Code's status line (ticket, last check, run) |
| `senior-mode setup statusline` | Writes the status line to the project's `.claude/settings.json` |
| `senior-mode item set <issue> <field> <option>...` | Sets board fields of a ticket, for example `Status Ready`; a field cached without options (`Paths`) takes text: `Paths "a/**,b.sh"` |
| `senior-mode item get <issue> [field]` | Reads the board fields of a ticket in one call: the value of `field`, or every field set (`#42 Status = Ready`) |
| `senior-mode config get <key>` | Prints a config value, with defaults (see [Configuration](configuration.md)) |
| `senior-mode protected [--base <ref>]` | Lists the files changed on the branch that match a `protected` glob (exit 0), or nothing (exit 1); used by the reviewer |
| `senior-mode context` | Prints the session greeting and the current ticket (used by the `SessionStart` hook) |
| `senior-mode frame start <idea>` | Makes the worktree `~/.local/share/senior-mode/worktrees/<repo>/frame-<slug>` (a framing opened elsewhere earlier is reused) and the branch `docs/<slug>` from `origin/main`; refuses when the default branch is ahead of origin |
| `senior-mode frame end` | Ends every framing session in the repository, so edits outside `docs/` are allowed again |

GitHub calls that fail for a passing reason (timeouts, server errors, rate limits) are retried up to
three times.
