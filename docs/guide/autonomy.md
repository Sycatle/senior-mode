# Autonomy and guardrails

What senior-mode blocks, what GitHub requires before a merge, and what is not automated yet.

The rule is "mechanisms over prose": what can be checked by a hook, a ruleset or a script is not
left to instructions. The design is in [spec §10](../specs/0001-senior-mode.md#10-autonomy-and-guardrails)
and [ADR 0003](../adr/0003-bounded-full-autonomy.md).

## Required statuses

Two commit statuses gate every merge to the default branch:

| Status | Set by | Meaning |
|---|---|---|
| `senior-mode/ci` | `senior-mode publish` after `senior-mode check` (local mode), or the workflow (actions mode) | The check list passed on that exact commit |
| `senior-mode/review` | The `reviewer` agent | `success` approved, `pending` approved for a human merge, `failure` changes requested |

A status published from your machine is only as trustworthy as that machine: it names the commit
it verified ([ADR 0006](../adr/0006-local-ci.md)). Teams that need independent CI use `actions` mode.

## The ruleset

`setup` creates a repository ruleset named `senior-mode` on the default branch. It:

- allows changes only through pull requests, merged by rebase;
- requires linear history, and blocks deleting the branch and force-pushing to it;
- requires `senior-mode/ci` and `senior-mode/review` on a branch that is up to date with the default
  branch;
- requires no approving review count (the `reviewer` status replaces it).

It adds to any existing protection and does not rewrite it. Repository admins may bypass it,
explicitly, with `gh pr merge --admin`. Agents may not: the Bash guard denies it.

On a private repository with a free GitHub plan, rulesets are refused. Setup says so and continues;
the git hooks and the Bash guard still apply, but GitHub will not enforce the statuses.

## `needs-human`

The `needs-human` label marks a pull request that waits for a person. Today it is added by the
[`review`](skills.md#review) skill when a diff touches a sensitive area: migrations, security, auth,
payments, CI, infrastructure, major dependency upgrades, an L ticket or an ADR. The verdict is then
at best "approve, human merge" and `senior-mode/review` stays `pending`. The `ops` agent never merges
a `needs-human` pull request.

## Protected zones

State: **Coming in [v0.3](https://github.com/Sycatle/senior-mode/milestone/3).**

The spec plans protected zones as globs in the config, with defaults per preset. Today there is no
`protected` key in the config written by setup, and no preset defaults: the reviewer judges
sensitive areas from the list above.

## Hooks

The plugin's hooks apply to the main session and to every agent.

### Bash guard (`guard-bash.sh`)

Runs before every Bash command, in any repository where the plugin is enabled. It denies:

- skipping checks: `--no-verify`, `git commit -n`, `git -c core.hooksPath=...`;
- force-push: `--force`, `-f`, `--force-with-lease`, `--force-if-includes`, a `+` refspec;
- pushing every branch: `--all`, `--mirror`, `--branches`;
- pushing to the default branch (open a pull request instead);
- `git reset --hard` on a shared branch (the default branch, or one that exists on `origin` or has
  an upstream);
- `gh pr merge --admin`, and a merge through `gh api` with `PUT` on `pulls/<n>/merge`.

It reads commands as written. It is a guardrail for honest mistakes, not a sandbox: `bash -c "..."`
and GraphQL calls are not parsed.

### Frame guard (`frame-guard.sh`)

Starting `/senior-mode:frame` marks the session as framing. While marked, edits outside `docs/` are
denied, subagents included. Another senior-mode command or skill, the end of the session, or
`senior-mode frame end` clears the mark. Only in repositories with `.claude/senior-mode.json`.

### Proof hook (`proof.sh`)

In repositories with `.claude/senior-mode.json`:

- after an edit, the session is marked "edited"; after a successful `senior-mode check` or one of
  the configured check commands, it is marked "verified";
- when Claude, or the `implementer` agent, tries to finish while "edited", it is blocked once and
  told to run `senior-mode check` and read the output, or to say plainly the change is not verified;
- before a conversation is compacted, the summary is told to keep the ticket, its spec, the
  decisions, the changed files and the verification state.

### Session greeting

At session start, a short router explains senior-mode. On a ticket branch (`<type>/<issue>-<slug>`)
it adds the ticket, its status, its spec and the first acceptance criteria. In a repository not yet
adopted, it suggests `/senior-mode:setup`.

## Other mechanisms

- **Git hooks.** `commit-msg` refuses a subject that is not a Conventional Commit. `pre-push` runs the
  check list. Both work in any terminal, without Claude Code.
- **Permissions.** Setup adds to `.claude/settings.json` an allow-list (the `senior-mode` script,
  read-only `git` and `gh` commands) and a deny-list that mirrors the Bash guard.

## What is not automated yet

| Feature | State |
|---|---|
| `run`: autonomous delivery and merge of up to N tickets | Coming in [v0.3](https://github.com/Sycatle/senior-mode/milestone/3) |
| Protected zones from config globs, with preset defaults | Coming in [v0.3](https://github.com/Sycatle/senior-mode/milestone/3) |
| Circuit breaker (stop after 2 failed tickets, or when a ticket outgrows its size) | Coming in [v0.3](https://github.com/Sycatle/senior-mode/milestone/3) |
| Self-protection during a run (deny edits to workflows, `.claude/`, `.githooks/`) | Arrives with `run`, [v0.3](https://github.com/Sycatle/senior-mode/milestone/3) |
| Scheduled runs (cron, cloud task, Actions) | Coming in [v0.3](https://github.com/Sycatle/senior-mode/milestone/3) |
| Spec drift check in the check list | Coming in [v0.2](https://github.com/Sycatle/senior-mode/milestone/2) |
| Automatic retry of the implementer on Opus | Arrives with `next` and `run` |
| Formatter after each edit, desktop notifications, auto-allowed check commands during a run | Planned in [spec §16](../specs/0001-senior-mode.md#hooks), no milestone yet |

Until `run` ships, nothing merges unless you ask for it.
