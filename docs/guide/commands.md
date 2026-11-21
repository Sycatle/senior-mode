# Commands

Every `/senior-mode:` command, what it asks you and what it produces, plus the `senior-mode` script.

Commands run only when you type them. The design is in [spec §7](../specs/0001-senior-mode.md#7-commands).

## Overview

| Command | Purpose | State |
|---|---|---|
| `/senior-mode:setup` | Adopt a repository, or repair it | Available |
| `/senior-mode:frame` | Turn an idea into a spec, ADRs and tickets | Available |
| `/senior-mode:next` | Daily session: deliver the top Ready ticket with you | Coming in [v0.2](https://github.com/Sycatle/senior-mode/milestone/2) |
| `/senior-mode:status` | Plain-language dashboard | Available |
| `/senior-mode:run` | Deliver up to N Ready tickets on its own | Coming in [v0.3](https://github.com/Sycatle/senior-mode/milestone/3) |
| `/senior-mode:retro` | Weekly review of the board and the process | Coming in [v0.4](https://github.com/Sycatle/senior-mode/milestone/4) |
| French aliases (`senior-mode-fr`) | `/cadre`, `/suivant`, `/lance`, `/etat`, `/retro`, `/installer` | Coming in [v0.4](https://github.com/Sycatle/senior-mode/milestone/4) |

## `setup`

State: **Available.**

- **Purpose.** Adopt a repository, new or existing. Safe to re-run: it repairs, never duplicates.
- **Asks you.** Whether to create a GitHub repository if there is none (private by default); to run
  `gh auth refresh -s project` if the scope is missing; where checks run (`local` or `actions`);
  your yes to the list of changes; for a stack without a `package.json`, how to lint, typecheck,
  test and build; your yes before adding a missing linter or test runner.
- **Produces.** A Project board with `Status`, `Priority` and `Size`; labels; rebase-only merges;
  the `senior-mode` ruleset; `.claude/senior-mode.json`; git hooks; `CLAUDE.md` Principles; PR and
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
  blockers; an epic with sub-issues for L), and a pull request with the documents on a branch
  `docs/<issue>-<slug>`. Ends with at most five lines, then proactive suggestions.
- **Limits.** A size S stops at once: it needs no framing. During framing, edits outside `docs/` are
  denied, subagents included. Re-running is safe: an open issue with the same title is reused.
  Tickets stay in Backlog until the documents pull request is merged and the spec accepted.

## `next`

State: **Coming in [v0.2 Daily loop](https://github.com/Sycatle/senior-mode/milestone/2).**

- **Purpose.** The daily session: a short state of the board, open pull requests needing a human,
  then the top Ready ticket delivered with you in the loop (tests first, commits, pull request).
- Until then, follow [A typical day](a-typical-day.md) steps 3 to 7.

## `status`

State: **Available.**

- **Purpose.** A cheap, plain-language dashboard: done since last time, in progress, in review,
  blocked or missing information, waiting for a human (`needs-human` pull requests, failing
  statuses), the next Ready tickets, and the release state. One GitHub call.
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
do not break it. A project status line replaces your personal one in that project; one the project
already has is kept. If the plugin is loaded with `--plugin-dir`, the line stays empty.

## `run`

State: **Coming in [v0.3 Autonomy](https://github.com/Sycatle/senior-mode/milestone/3).**

- **Purpose.** Deliver up to N Ready tickets (default 3) without you, merging only within the
  guardrails of [spec §10](../specs/0001-senior-mode.md#10-autonomy-and-guardrails), and report in
  plain language.
- See [Autonomy](autonomy.md#what-is-not-automated-yet).

## `retro`

State: **Coming in [v0.4 Breadth](https://github.com/Sycatle/senior-mode/milestone/4).**

- **Purpose.** Weekly: reprioritise, close or rescope stale items, list debt, check spec drift, and
  propose tickets that turn recurring mistakes into checks.

## The `senior-mode` script

The plugin puts a `senior-mode` script on the PATH of Claude's Bash tool. Claude uses it; you can
too, with `!` at the Claude Code prompt. All of it is available today.

| Command | What it does |
|---|---|
| `senior-mode setup github [--ci local\|actions]` | The GitHub side of setup: Project, fields, labels, merge settings, workflows, ruleset |
| `senior-mode setup repo [--command <name>=<cmd>]...` | The repository side of setup; `--command` stores a lint, typecheck, test, build (or, for node, e2e) command and its check |
| `senior-mode check` | Runs the check list; on a clean tree, records the result for the current commit |
| `senior-mode publish [commit]` | Sends the recorded result to GitHub as `senior-mode/ci` (the commit must be pushed) |
| `senior-mode release [--dry-run]` | Runs release-please 17.11.2 locally: tags a merged release PR, opens or updates the next one |
| `senior-mode issue create --title ... --body-file ... --size ... --priority ...` | Creates a ticket with board fields, and optionally `--status`, `--milestone`, `--type`, `--blocked-by`, `--parent`; reuses an open issue with the same title |
| `senior-mode pick [--json] [--max N]` | The Ready tickets in delivery order: Priority, then milestone due date; leaves out size L, blocked tickets and `needs-info` |
| `senior-mode status [--json] [--since <dur>] [--watch [secs]]` | The dashboard of `/senior-mode:status`; `--since 7d` for a digest (`m`, `h`, `d`, `w`) |
| `senior-mode statusline` | One offline line for Claude Code's status line (ticket, last check, run) |
| `senior-mode setup statusline` | Writes the status line to the project's `.claude/settings.json` |
| `senior-mode item set <issue> <field> <option>...` | Sets board fields of a ticket, for example `Status Ready` |
| `senior-mode config get <key>` | Prints a config value, with defaults (see [Configuration](configuration.md)) |
| `senior-mode protected [--base <ref>]` | Lists the files changed on the branch that match a `protected` glob (exit 0), or nothing (exit 1); used by the reviewer |
| `senior-mode context` | Prints the session greeting and the current ticket (used by the `SessionStart` hook) |
| `senior-mode frame end` | Ends every framing session in the repository, so edits outside `docs/` are allowed again |

GitHub calls that fail for a passing reason (timeouts, server errors, rate limits) are retried up to
three times.
