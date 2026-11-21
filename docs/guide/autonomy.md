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

The `needs-human` label marks a pull request that waits for a person. It is added by the
[`review`](skills.md#review) skill when a diff matches a [protected zone](#protected-zones) or touches
another sensitive area: migrations, security, auth, payments, CI, infrastructure, major dependency
upgrades, an L ticket or an ADR. The verdict is then
at best "approve, human merge" and `senior-mode/review` stays `pending`. The `ops` agent never merges
a `needs-human` pull request.

## Protected zones

`protected` in `.claude/senior-mode.json` is a list of globs. `setup` writes the preset's defaults
when the key is absent and never overwrites a list that is there, even an empty one (your way to
opt out). Edit it freely.

```
senior-mode protected [--base <ref>]
```

Prints the files changed on the current branch since it left the base (by default the default
branch) that match a glob, one per line. Exit 0 when there are matches, 1 when there are none.

A glob without a slash matches a name at any depth (`Dockerfile*`, `.env*`). A glob with a slash is
anchored at the repository root: `*` stays inside one path segment, `**/` spans any number of
directories (`**/migrations/**`), `?` is one character.

The `node` and `generic` presets protect:

| Zone | Globs |
|---|---|
| Migrations | `**/migrations/**` |
| Auth, security, permissions | `**/auth/**`, `auth.*`, `**/security/**`, `SECURITY.md`, `**/permissions/**`, `**/rbac/**` |
| Secrets | `.env*`, `**/secrets/**`, `*.pem`, `*.key` |
| Payments | `**/payments/**`, `**/billing/**`, `**/stripe/**` |
| CI and git hooks | `.github/workflows/**`, `.github/actions/**`, `.github/CODEOWNERS`, `.githooks/**`, `.gitlab-ci.yml` |
| Infrastructure, containers | `Dockerfile*`, `docker-compose*`, `compose.y*ml`, `**/infra/**`, `**/terraform/**`, `**/k8s/**`, `*.tf` |
| senior-mode config | `.claude/settings*.json`, `.claude/senior-mode.json` |
| Next.js projects (`framework`) | `middleware.*`, `src/middleware.*` |

The [`review`](skills.md#review) skill and the `reviewer` agent run `senior-mode protected`: a match
means the `needs-human` label and a `pending` review status. The globs are a floor: the reviewer
still judges what they cannot see (major dependency upgrades, an L ticket, an ADR).

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

### Self-protection (`self-protect.sh`)

Active only while the environment variable `SENIOR_MODE_RUN=1` is set, which `run` does for the
sessions it starts. Outside a run it does nothing. It denies Edit, Write, MultiEdit and NotebookEdit
on `.github/workflows/**`, `.claude/**` and `.githooks/**` at the repository root, and Bash
commands that obviously write there: redirections, `tee`, `cp`, `mv`, `rm`, `touch`, `truncate`,
`install`, `ln`, `dd of=`, `sed -i`, `perl -i`, `git rm`, `git mv`, `git checkout` and
`git restore` on those paths. An agent therefore cannot weaken the checks, the hooks or the
protected-zone list (which lives in `.claude/senior-mode.json`). `.claude/agent-memory/**` stays
writable: the reviewer and architect agents keep their project memory there. The reason it gives tells the agent to
leave the change out and say in the pull request that a human must make it.

Like the Bash guard, it reads commands as written: a guardrail for honest mistakes, not a sandbox.

### Secrets guard (`guard-secrets.sh`)

Runs before every `Read`, `Grep`, `Glob` and Bash command, in any repository where the plugin is
enabled, during a run or not. It keeps secrets out of the conversation. It denies:

- `Read`, `Grep` and `Glob` on `.env` and `.env.*`, `*.pem`, `*.key`, `id_rsa*`, `id_ed25519*`, `*.p12`,
  `*.pfx`, `.npmrc`, `.netrc`, `credentials*.json`, `service-account*.json`, and the globs of the
  [`secrets` key](configuration.md#keys-the-plugin-reads-today);
- Bash commands that print such a file (`cat`, `less`, `more`, `head`, `tail`, `grep`, `rg`, `source`,
  `.` and a few more), and ones that dump the environment: `printenv`, bare `env`, bare `set`,
  `export -p`, `declare -x`, `/proc/<pid>/environ`.

`.env.example`, `.env.sample`, `.env.template` (and `.env.local.example`) and public keys (`*.pub`) are
allowed. The deny message says why and what to do instead: ask the human for the value you need, or read
`.env.example` for the variable names.

It reads commands as written. It is a guardrail for honest mistakes, not a sandbox: `bash -c "..."`,
a script that reads the file, `cat *` or a variable that already holds a secret are not caught. Keep only
dev-only secrets on a machine where agents run; `setup` says so.

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

## Run

`/senior-mode:run` ([ADR 0007](../adr/0007-hybrid-run-orchestration.md)) starts one headless Claude
session per ticket, each in its own worktree, with `SENIOR_MODE_RUN=1`. The `senior-mode run`
command, not a model, applies these bounds:

- **Batch:** at most `autonomy.maxTickets` tickets (default 3), `autonomy.parallel` at a time
  (default 1), taken in the order of `senior-mode pick`.
- **Retry on Opus:** a ticket that fails on Sonnet is tried once more on Opus, from the same worktree
  (`autonomy.escalate`, default true).
- **Circuit breaker:** after `autonomy.maxConsecutiveFailures` failed tickets in a row (default 2), or
  as soon as a ticket outgrows its size, no new ticket starts. A failed ticket goes back to Backlog
  with a comment that says why; its branch and worktree are kept.
- **Proof:** a session counts as delivered only if a pull request is open for its branch.
- **Merge** ([ADR 0008](../adr/0008-merge-off-by-default.md)): off by default. With
  `autonomy.merge: true`, a pull request merges (`gh pr merge --rebase`) only when `senior-mode/ci`
  and `senior-mode/review` are both `success` on its head, it has no `needs-human` label, and the
  server enforces protection (`github.protection` is not `none`). Everything else waits for a human,
  and the report says why.
- **End-to-end suites** share `e2e.slots` slots per machine (default 2): `check` runs the check named
  `e2e` through `senior-mode e2e-lock`, which exports the slot number as `SENIOR_MODE_E2E_SLOT`.

### Scheduled runs

`senior-mode schedule install [--at HH:MM] [--max N]` runs `senior-mode run` every day on the machine
you are on, with its own Claude login: no API key, no budget flag
([ADR 0012](../adr/0012-scheduled-runs-on-the-agent-machine.md)). The time is `--at`, else
`autonomy.schedule`, else `02:00`; `--max` is passed to `run`, which otherwise reads
`autonomy.maxTickets`.

- **systemd.** It writes `~/.config/systemd/user/senior-mode-run-<repo>.service` and `.timer`
  (`Persistent=true`: a run missed while the machine was off starts at the next boot) and enables the
  timer with `systemctl --user`. Without a user systemd, it adds one crontab line tagged
  `# senior-mode-run:<repo>` instead.
- **Login shell.** The command is `bash -lc`, so `claude` is found in `~/.local/bin` as in your
  terminal. Like `run`, it refuses to install as root.
- **Linger.** A user timer fires only while you have a session unless linger is on. Install warns when
  it is off; the fix is `sudo loginctl enable-linger $USER`.
- **Check it.** `senior-mode schedule status` prints the next trigger and the last result: from the
  journal (`journalctl --user -u senior-mode-run-<repo>`), or from `.git/senior-mode/schedule.log`
  for cron.
- **Undo it.** `senior-mode schedule remove` disables and deletes the units, or the tagged line.
  Install and remove can be repeated: they never duplicate or fail when nothing is there.

## Other mechanisms

- **Git hooks.** `commit-msg` refuses a subject that is not a Conventional Commit. `pre-push` runs the
  check list. Both work in any terminal, without Claude Code.
- **Permissions.** Setup adds to `.claude/settings.json` an allow-list (the `senior-mode` script,
  read-only `git` and `gh` commands) and a deny-list that mirrors the Bash guard.

## What is not automated yet

| Feature | State |
|---|---|
| Spec drift check in the check list | Coming in [v0.2](https://github.com/Sycatle/senior-mode/milestone/2) |
| Retry on Opus in `next` (it exists in `run`) | Arrives with `next` |
| Formatter after each edit, desktop notifications, auto-allowed check commands during a run | Planned in [spec §16](../specs/0001-senior-mode.md#hooks), no milestone yet |

Nothing merges unless you ask for it: by hand, or with `autonomy.merge: true` for `run`.
