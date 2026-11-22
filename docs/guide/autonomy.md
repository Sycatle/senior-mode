# Autonomy and guardrails

What senior-mode blocks, what GitHub requires before a merge, and what is not automated yet.

The rule is "mechanisms over prose": what can be checked by a hook, a ruleset or a script is not
left to instructions. The design is in [spec §10](../specs/0001-senior-mode.md#10-autonomy-and-guardrails)
and [ADR 0003](../adr/0003-bounded-full-autonomy.md).

## Required statuses

Three commit statuses gate every merge to the default branch:

| Status | Set by | Meaning |
|---|---|---|
| `senior-mode/ci` | `senior-mode publish` after `senior-mode check` (local mode), or the workflow (actions mode) | The check list passed on that exact commit |
| `senior-mode/review` | The `reviewer` agent | `success` approved, `pending` approved for a human merge, `failure` changes requested |
| `senior-mode/security` | `senior-mode publish` when the pass is not due, else the `security` agent | `success` no high or critical finding (or "not required"), `pending` due and not done, `failure` a high or critical finding |

The security pass is due when the pull request touches a [protected zone](#protected-zones) (zones as
the base branch has them) or closes a size L ticket. `publish` then leaves `senior-mode/security`
pending, and the [`security`](agents.md#security) agent reviews the pull request on Opus: with a high or
critical finding it sets `failure` and the pull request gets `needs-human`. Any other pull request
gets `success` with "not required: no protected zone, not L". A pull request that closes no issue
(release, framing) is in that case: only protected zones and L tickets require the pass. The limit:
a pull request that closes a small issue while doing L-sized work cannot be detected mechanically, so
the `reviewer` flags it. When `publish` cannot read the pull request or the Size of a ticket, it
leaves the status pending rather than guess. `publish` replaces only its own statuses ("not
required", "required: ..."): a `failure` or `success` set by the `security` agent on a commit is
never overwritten. After `senior-mode setup github` adds the third check to an existing
repository, a pull request opened before needs `senior-mode publish` once more on its head. See
[ADR 0015](../adr/0015-security-posture.md).

Until the reviewer runs in a separate session ([#150](https://github.com/Sycatle/senior-mode/issues/150)),
a ticket session can post `senior-mode/security` itself: the Bash guard does not block statuses.
`run` checks the protected zones itself before it merges, whatever the statuses say, so only the
auto-merge of an L ticket depends on this status being honest.

A status published from your machine is only as trustworthy as that machine: it names the commit
it verified ([ADR 0006](../adr/0006-local-ci.md)). Teams that need independent CI use `actions` mode.

## The ruleset

`setup` creates a repository ruleset named `senior-mode` on the default branch. It:

- allows changes only through pull requests, merged by rebase;
- requires linear history, and blocks deleting the branch and force-pushing to it;
- requires `senior-mode/ci`, `senior-mode/review` and `senior-mode/security` on a branch that is up to date with the default
  branch;
- requires no approving review count (the `reviewer` status replaces it), except for code owners:
  when `protected` has globs, it requires code owner review (see below).

It adds to any existing protection and does not rewrite it. Repository admins may bypass it,
explicitly, with `gh pr merge --admin`. Agents may not: the Bash guard denies it.

### Code owners

When `protected` has globs, `setup github` writes `.github/CODEOWNERS` with one line per glob
owned by the repository owner (on an organization, by the user signed in to `gh`), inside a block
marked `# senior-mode:begin` and `# senior-mode:end`, and the ruleset requires code owner review. A
rerun rewrites only that block: entries you add by hand, above or below it, are kept. In a new
block at the end of an existing file, the block wins where patterns overlap, as GitHub reads the
last match. A glob CODEOWNERS cannot express (whitespace, a leading `#` or `!`, brackets) is named
on every run and recorded as a comment in the block, then left out: nobody owns that zone. Setup
writes the file and does not commit it: commit it, as the ruleset reads the copy on the default
branch. Until the default branch holds the file, code owner review enforces nothing, and each run
says so, a rerun that changes nothing included.

GitHub reads `.github/CODEOWNERS` before a `CODEOWNERS` at the root or in `docs/`. Setup does not
create that shadow over a file of yours: it says so and writes nothing; move your file to
`.github/CODEOWNERS` and rerun. Where `.github/CODEOWNERS` already exists next to one of them, the
other is named on each run as ignored. On a first setup, `setup github` runs before `setup repo`
has written `protected`: `setup repo` then says to rerun `setup github`.

Agents act with the owner's identity, and GitHub never lets an author approve their own pull
request. A pull request that touches a protected zone therefore cannot get the required review: the
owner merges it by hand with `gh pr merge --admin`, which the Bash guard denies to agents. That is
the intended "merging a protected zone stays human" until agents get an identity of their own
(#175).

On a private repository with a free GitHub plan, rulesets are refused. Setup says so and continues;
the git hooks and the Bash guard still apply, but GitHub will not enforce the statuses.

### GitHub's scanners

`setup github` also switches on Dependabot alerts, secret scanning and
push protection (`vulnerability-alerts` and `security_and_analysis` of the
repository API), and says for each whether it is `on` or `not enabled` with GitHub's reason: a plan
that refuses (HTTP 403 or 422, as private repositories without GitHub Advanced Security do) does not
stop setup. It does not turn on Dependabot security updates and writes no `.github/dependabot.yml`:
GitHub offers no severity filter for security-update pull requests, so they would come for every
severity, and alerts become issues only (below). A `dependabot.yml` of your own is left untouched, and
setup says so.

When `run` starts and when `retro` runs, each open high or critical Dependabot alert and each open
secret-scanning alert (treated as critical) gets one `security` issue, through
`senior-mode issue create --kind --path --rule`: the alert's `security-id` makes a second pass file
nothing new. The body names the package or secret type and links the alert; it holds no
vulnerability detail and never the secret's value, and no repository security advisory is opened for
an alert (`--no-advisory`): it is a dependency's CVE or a leaked token, not a flaw in your own code. Moderate and low alerts stay as alerts on GitHub.
An alert list GitHub refuses (scanning not enabled, no permission, 404) is reported and does not stop
the command.

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
| Next.js projects (`framework`) | `middleware.*`, `src/middleware.*`, `proxy.*`, `src/proxy.*` |

The [`review`](skills.md#review) skill and the `reviewer` agent run `senior-mode protected`: a match
means the `needs-human` label and a `pending` review status. The globs are a floor: the reviewer
still judges what they cannot see (major dependency upgrades, an L ticket, an ADR).

## Hooks

The plugin's hooks apply to the main session and to every agent.

### Bash guard (`guard-bash.sh`)

Runs before every Bash command, in any repository where the plugin is enabled. It denies:

- skipping checks: `--no-verify`, `git commit -n`, `git -c core.hooksPath=...` (or
  `--config-env`), a `GIT_CONFIG_KEY_<n>=core.hooksPath` or `GIT_CONFIG_PARAMETERS` environment
  setting, and setting or unsetting `core.hooksPath` with `git config`, an empty value included
  (reading it is allowed). An empty quote pair or an unquoted backslash inside a word (`--no""-verify`,
  `--for\ce`, `core.hooksPath\=x`, `\+main`) does not hide it, the backslash being dropped as the
  shell does (an escaped space or quote goes with it);
- `gh alias set` and `gh alias import`: an alias hides the command it runs from this guard;
- force-push: `--force`, `-f`, `--force-with-lease`, `--force-if-includes`, a `+` refspec;
- pushing every branch: `--all`, `--mirror`, `--branches`;
- pushing to the default branch (open a pull request instead);
- `git reset --hard` on a shared branch (the default branch, or one that exists on `origin` or has
  an upstream);
- `gh pr merge --admin`, and a merge through `gh api` with `PUT` on `pulls/<n>/merge`, even when
  the number is a variable. `env`, `sudo`, `xargs` and the like in front of `gh` or `git` do not
  hide the command; for `gh api`, only the endpoint counts, not the text of a `-f body=...`, as long
  as the quoting is plain (with a backslash, `$'...'` or a command substitution the whole command
  is read, a method that cannot be read there counts as a write unless every one says `GET`, and a
  body that names a ruleset path is then denied too);
- in a `run` session (`SENIOR_MODE_RUN=1`), any merge: `gh pr merge`, and through `gh api` the
  merge endpoints and the `mergePullRequest` and `enablePullRequestAutoMerge` mutations; and any
  write to rulesets or branch protection, through `gh api` paths or GraphQL ruleset and
  branch-protection mutations. `gh pr list --search merge` and other read-only calls are allowed.

It reads commands as written. It is a guardrail for honest mistakes, not a sandbox: `bash -c "..."`
and other GraphQL calls are not parsed.

### Self-protection (`self-protect.sh`)

Active only while the environment variable `SENIOR_MODE_RUN=1` is set, which `run` does for the
sessions it starts. Outside a run it does nothing. It denies Edit, Write, MultiEdit and NotebookEdit
on `.github/workflows/**`, `.claude/**` and `.githooks/**` at the repository root, and on the git
hooks, `.git/config` and `config.worktree` of the common dir (every worktree shares them), and
the `.git` directory itself (`rm -rf .git`, `rm -rf .git/*`), and Bash commands that obviously write
there: redirections, `tee`, `cp`, `mv`, `rm`, `touch`, `truncate`, `chmod`, `chown`, `chgrp`,
`install`, `ln`, `dd of=`, `sed -i`, `perl -i`, `git rm`, `git mv`, `git checkout` and
`git restore` on those paths, also behind `sudo`, `env`, `xargs`, `nice`, `doas` and the like. An agent therefore cannot weaken the checks, the hooks or the
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

### Sessions without a human

A headless session (`claude -p`, a `run` session, a scheduled batch) cannot be asked anything. The
rule: a reversible choice takes the recommended option, and the report says so; an L spec, any ADR,
a missing branch protection or a protected zone is never accepted or touched: the document stays
`draft` or `proposed`, the issue or pull request gets `needs-human`, and that step stops with a
report. A headless session in a workspace Claude Code does not trust yet ignores the project's
permissions in `.claude/settings.json`: open the folder once interactively and accept the trust
prompt, or pass the permissions on the command line. `senior-mode run` passes
`--permission-mode bypassPermissions` and relies on the guard hooks.

### Frame guard (`frame-guard.sh`)

Starting `/senior-mode:frame` marks the session as framing. While marked, edits outside `docs/` and
`.claude/agent-memory/` (the agents' project memory) are denied, subagents included. `docs/` of any
worktree of the repository counts, since a framing works in its own (`senior-mode frame start`).
Another senior-mode command or skill, the end of the session, or `senior-mode frame end` clears the
mark. Only in repositories with `.claude/senior-mode.json`.

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

- **WIP:** `run` is bounded by `autonomy.parallel`, not by `wip`. It proves it is the caller with a
  random token, kept in its memory and in a `0600` file of the run's directory that it removes when it
  ends; `start` skips `wip` only when the two match. `SENIOR_MODE_RUN=1` set by hand does not: it
  only marks a session as unattended for the guards. This stops an accidental or hand-set bypass, not a
  process of the same user bent on it.
- **Alerts first:** before it looks at the board, `run` files the open high or critical alerts of
  GitHub's scanners as issues (see [GitHub's scanners](#githubs-scanners)).
- **Batch:** at most `autonomy.maxTickets` tickets (default 3), `autonomy.parallel` at a time
  (default 1), taken in the order of `senior-mode pick`.
- **Retry on Opus:** a ticket that fails on Sonnet is tried once more on Opus, from the same worktree
  (`autonomy.escalate`, default true).
- **Circuit breaker:** after `autonomy.maxConsecutiveFailures` failed tickets in a row (default 2), or
  as soon as a ticket outgrows its size, no new ticket starts. A failed ticket goes back to Backlog
  with a comment that says why; its branch and worktree are kept.
- **Session timeout:** a session still running after `autonomy.sessionTimeout` minutes (default 90,
  at most 1440) is killed: the signal reaches its process group, so what the session started in it
  stops too, but not a process that left the group. The ticket gets the `needs-human` label and a
  comment with the log path, counts as a failure for the circuit breaker, and is not retried on Opus:
  a stuck session is not failed work ([ADR 0014](../adr/0014-model-escalation-in-runs.md)). Its Status
  stays In progress; the label is the signal. Where the session has no group of its own (no tmux and
  no `setsid`, as on macOS), it is not killed: `run` says so, and still labels and records the ticket.
  The docs session that follows merges is bounded by the same timeout and killed the same way. It has
  no ticket, so nothing is labelled: `run` says so on stderr and in its report, and records the outcome
  in `docs-outcome.json` next to the ticket records (`retro` does not read it). Its branch and worktree
  are kept, and `run` ends normally.
- **Guards at the start** (with the `claude` CLI): `run` refuses to start unless the plugin is enabled
  for ticket sessions and its `hooks/hooks.json` is present. Ticket sessions run in fresh worktrees of
  the default branch, so only `enabledPlugins` in the user settings (`~/.claude/settings.json`, or
  `CLAUDE_CONFIG_DIR`) and in the `.claude/settings.json` committed on the default branch count, not
  an untracked `settings.local.json`; a plugin loaded with `--plugin-dir` counts. Once a day it also
  runs a short probe session (Haiku), in a throwaway worktree of the default branch, asked to run
  `git -c core.hooksPath=... init` on a temporary directory, a command the Bash guard denies and that
  is harmless if it is not denied. If the deny does not show in the session's output, or the
  directory was created, `run` starts nothing and says so; the output is in
  `.git/senior-mode/probe.log`. The date of the last pass is in `.git/senior-mode/probe`. The probe is
  stopped after 5 minutes (`SENIOR_MODE_PROBE_TIMEOUT`, in seconds), on every platform: a probe that
  does not answer counts as failed. Under another `agent.command` none of this runs: those hooks do
  not hold there anyway.
- **Proof:** a session counts as delivered only if a pull request is open for its branch.
- **Merge** ([ADR 0008](../adr/0008-merge-off-by-default.md)): off by default. With
  `autonomy.merge: true`, a pull request merges (`gh pr merge --rebase`) only when `senior-mode/ci`,
  `senior-mode/review` and `senior-mode/security` are all `success` on its head, it has no `needs-human` label, the
  server enforces protection (`github.protection` is `ruleset`), and none of its files matches a
  protected zone of the default branch: `run` checks that itself, it does not rely on the reviewer.
  The merge names the head it checked (`--match-head-commit`), so a later push is refused.
  Everything else waits for a human, and the report says why. The ticket session itself never
  merges: the Bash guard denies it any merge.
- **Agent:** the headless CLI is `agent.command` (default `claude`), for the tickets and the docs
  session, scheduled or not. Another compatible CLI, such as syacode, can replace it, but senior-mode's
  hooks and guards do not hold under it until it implements them (Sycatle/syacode#13 to #18): use it
  only on a machine where that is acceptable.
- **End-to-end suites** share `e2e.slots` slots per machine (default 2): `check` runs the check named
  `e2e` through `senior-mode e2e-lock`, which exports the slot number as `SENIOR_MODE_E2E_SLOT`. The lock files live in `$XDG_RUNTIME_DIR/senior-mode-e2e`, else in
  a private `senior-mode-e2e-<uid>` directory of `$TMPDIR` (or `/tmp`); a directory that is a link, not yours or not
  mode 0700 is refused.

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
| Spec drift check in the check list | Planned, no milestone yet; today the reviewer checks it |
| Retry on Opus in `next` (it exists in `run`) | Not planned: in `next` you decide |
| Formatter after each edit, desktop notifications, auto-allowed check commands during a run | Planned in [spec §16](../specs/0001-senior-mode.md#hooks), no milestone yet |

Nothing merges unless you ask for it: by hand, or with `autonomy.merge: true` for `run`.
