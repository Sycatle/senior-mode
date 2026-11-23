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

A session with a [role](#session-roles) other than `reviewer` cannot post `senior-mode/review`: the
Bash guard denies it. `senior-mode/security` is still open to a ticket session until the `security`
agent gets a role of its own. `run` checks the protected zones itself before it merges, whatever the
statuses say, so only the auto-merge of an L ticket depends on that status being honest.

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
never lowers a protection: the ruleset requires code owner review when the block owns a zone, when
the CODEOWNERS file GitHub reads (`.github/`, then the root, then `docs/`; a shadowed file and a
file with broken markers included) has any owner entry, or when the ruleset already requires it or cannot be read (a read
error says nothing of its content), and
each run says which reason kept it on. With none of these, setup says it is not required and
sends false. An empty `protected` list is the one deliberate way to turn it off. Setup writes the
file and does not commit it: commit it, as the ruleset reads the copy on the default branch. Until the default branch holds the file, code owner review enforces nothing, and each run
says so, a rerun that changes nothing included.

GitHub reads `.github/CODEOWNERS` before a `CODEOWNERS` at the root or in `docs/`. Setup does not
create that shadow over a file of yours: it says so and writes nothing; move your file to
`.github/CODEOWNERS` and rerun (with both a root and a `docs/` file, GitHub already ignores the
`docs/` one, and setup says only the root's ownership would be lost). Where `.github/CODEOWNERS` already exists next to one of them, the
other is named on each run as ignored. On a first setup, `setup github` runs before `setup repo`
has written `protected`: `setup repo` then says to rerun `setup github`, and keeps saying so while no
managed block exists, as after a refusal over a shadowed file.

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

### Alerts

`senior-mode serve` (and `run`) tells the human instead of waiting to be watched. A ticket that is
labelled `needs-human` (a session that timed out, vanished or was stopped) or that failed gets the
`needs-human` label and a comment that mentions `notify.mention` (the repository owner when empty).
When `notify.webhook` is set, each alert is also sent as a JSON `POST`
`{"event", "repo", "number", "url", "reason"}`, where `event` is `needs-human`, `failed` or `breaker`.
The circuit breaker's pause has no ticket: it is only sent to the webhook (`number` and `url` are
`null`) and written on stderr. A webhook that does not answer is reported on stderr and never stops
`serve`.

Once a day (`notify.digest`, default true) `serve` posts `senior-mode status --since 24h` as a
Project status update. The time of the last attempt is kept in `.git/senior-mode/serve/digest`: a
failed post is tried again the next day.

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
  shell does (an escaped space or quote stays one character, so `core.hooksPath \ ` is a value, not
  nothing). A long option or a git or gh command split by a variable (`--for${x}ce`, `pu${x}sh`) is
  denied, and so is a config key split by one (`core.hooks${x}Path`, also quoted, in `git config`, `-c`,
  `--config-env` and `GIT_CONFIG_KEY_<n>`); a variable alone (`git $sub`, `git push origin $B`,
  `git config core.$k v`, `git config "$key" v`) is not followed. `GIT_CONFIG_NOSYSTEM` set to a true
  value is denied too: it drops the system config, where a policy such as `core.hooksPath` may sit;
- git takes an unambiguous abbreviation of a long option, so a prefix of a denied option is denied as
  the option itself: `--no-v` up to `--no-verif` for `--no-verify`, `--for`, `--forc`, `--force-w`... for
  the force options of `git push`, `--al`, `--m`, `--b` for `--all`, `--mirror`, `--branches`, `--h` for
  `git reset --hard`, `--ed` for `git config --edit`, and the abbreviations of `--unset`, `--unset-all`,
  `--replace-all` and `--add` on `core.hooksPath`. The minimum length is the shortest prefix git
  accepts (tested with git 2.43); shorter prefixes are ambiguous and git rejects them. `gh` (cobra)
  does not abbreviate (`gh pr merge --admi` is an unknown flag), so its options are read in full;
- the indirections that reach the same switches: `GIT_CONFIG_GLOBAL` and `GIT_CONFIG_SYSTEM` set to
  any file, `git config --edit` (an editor writes any key), `include.path` and `includeIf.<cond>.path`
  set through `git config`, `-c`, `--config-env` or the environment (`git config --file <f>` is read
  by its key like any other), and an `alias.<name>` whose value contains `--no-verify`, `--force`,
  an abbreviation of them, `push -f` (any short cluster with `f`), `commit -n` or `core.hooksPath` (the
  value is read anywhere in the command). Reading any of these keys is allowed;
- `gh alias set` and `gh alias import`: an alias hides the command it runs from this guard;
- force-push: `--force`, `-f`, `--force-with-lease`, `--force-if-includes`, a `+` refspec;
- pushing every branch: `--all`, `--mirror`, `--branches`;
- pushing to the default branch (open a pull request instead), also when a variable splits its name
  (`ma${x}in`, `HEAD:ma${x}in`); a ref that is only a variable (`HEAD:$BRANCH`) is not followed;
- `git reset --hard` on a shared branch (the default branch, or one that exists on `origin` or has
  an upstream);
- `gh pr merge --admin`, and a merge through `gh api` with `PUT` on `pulls/<n>/merge`, even when
  the number is a variable. `env`, `sudo`, `xargs` and the like in front of `gh` or `git` do not
  hide the command, and the endpoint is read up to any character that cannot continue the path
  (`pulls/5/merge;`, `merge|`, `merge)`). A `gh api` write whose endpoint is only a variable (`-X PUT
  "$EP"`, a `-f` or `--input` with `$EP`) is denied, since where it goes cannot be read; `-X $M` is
  not followed, and an endpoint that only ends in a variable-built `/merge` or `/protection` path
  (`-X PUT "$BASE/merge"`) counts as the endpoint it names. For `gh api`, only the endpoint counts, not the text of a `-f body=...`, as long
  as the quoting is plain (with a backslash, `$'...'` or a command substitution the whole command
  is read, without its backslashes (`pulls/5/me\rge`, `rule\sets`), a method that cannot be read
  there counts as a write unless every one says `GET`, a command with no `-X`, `-f`, `-F`, `--field`,
  `--raw-field` or `--input` is a GET, and a body that names a ruleset path is then denied too);
- in a `run` session (`SENIOR_MODE_RUN=1`), any merge: `gh pr merge`, and through `gh api` the
  merge endpoints and the `mergePullRequest` and `enablePullRequestAutoMerge` mutations; and any
  write to rulesets or branch protection, through `gh api` paths or GraphQL ruleset and
  branch-protection mutations. `gh pr list --search merge` and other read-only calls are allowed.

It reads commands as written. It is a guardrail for honest mistakes, not a sandbox: `bash -c "..."`,
`eval` and `sh -c` strings are not parsed, a variable holding a value (a method, a branch, a config key)
is not followed, a `GIT_CONFIG_PARAMETERS` value that hides a `$` is refused rather than read, and other
GraphQL calls are not parsed. A `cd` earlier in the command is not followed either (`cd /other &&
git push` is read from the starting directory). Other limits: an `includeIf.<cond>.path` key split by
a variable, a variable in a word of a ref that is not the default branch, an endpoint split in the
middle of `merge` (`/me${x}rge`), and an alias that runs a denied command by another route (`!sh -c`).

### Self-protection (`self-protect.sh`)

Active only while the environment variable `SENIOR_MODE_RUN=1` is set, which `run` does for the
sessions it starts, and, for the red tests only, in a session with `SENIOR_MODE_ROLE=ticket` (see
[Session roles](#session-roles)). Otherwise it does nothing. It denies Edit, Write, MultiEdit and NotebookEdit
on `.github/workflows/**`, `.claude/**` and `.githooks/**` at the repository root, and on the git
hooks, `.git/config` and `config.worktree` of the common dir (every worktree shares them), the
`.git` directory itself (`rm -rf .git`, `rm -rf .git/*`), and its `refs`, `packed-refs`, `HEAD`,
`objects`, `info` and `modules` and `worktrees` (`rm -rf .git/refs`; use `git worktree remove`). A
relative `.git/...` path from a linked worktree is denied too (`.git` is a file there, so it would
fail anyway). In a run it also denies the commands that discard what cannot be brought back:
`git update-ref -d` on a branch or `HEAD`, `git reflog expire` and `delete`, `git gc --prune=now` (or
`all`) and `git prune --expire now`, abbreviations included (`--pr=now`); a dry run (`--dry-run`, `-n`)
of `reflog expire` or `prune` is allowed, and so is the recovery of a main checkout (`rm .git/index.lock`,
`rm -rf .git/rebase-merge`), which is not one of the protected files; `git update-ref --stdin` with
`delete` lines is not read. A `cd` with a literal path earlier in the command is followed: a
relative path is checked from the starting directory and from where the `cd` went (`cd .git && rm -rf
hooks`); `cd`, `cd -` and `cd $dir` are not. Bash commands that obviously write
there: redirections, `tee`, `cp`, `mv`, `rm`, `touch`, `truncate`, `chmod`, `chown`, `chgrp`,
`install`, `ln`, `dd of=`, `sed -i`, `perl -i`, `git rm`, `git mv`, `git checkout` and
`git restore` on those paths, also behind `sudo`, `env`, `xargs`, `nice`, `doas` and the like. An agent therefore cannot weaken the checks, the hooks or the
protected-zone list (which lives in `.claude/senior-mode.json`). `.claude/agent-memory/**` stays
writable: the reviewer and architect agents keep their project memory there. The reason it gives tells the agent to
leave the change out and say in the pull request that a human must make it.

Like the Bash guard, it reads commands as written: a guardrail for honest mistakes, not a sandbox.

### Session roles

`SENIOR_MODE_ROLE` says what a session is for ([ADR 0017](../adr/0017-daemon-orchestration.md)): the
process that starts the session sets it (`serve`, or a human who wants the same limits), and the hooks
read it. Without it (a manual session) nothing below applies and the guards behave as before.

| Role | May | May not |
|---|---|---|
| `ticket` | Edit code, add tests of its own, commit, push, open the pull request | Post `senior-mode/review`; edit, move or delete a red test (below) |
| `test-author` | Write and commit the failing tests of an M ticket | Post `senior-mode/review` (it also edits no production code, by instruction) |
| `reviewer` | Post `senior-mode/review` | Edit files (the agent has no Edit or Write tool) |
| `integrator` | Merge pull requests as `serve` does | Post `senior-mode/review` |

Any role but `reviewer` is denied `senior-mode/review`, as a status with that context posted with
`gh api .../statuses/<sha>` (a write, or any `gh api graphql` that names it), or `curl` with a body to
a statuses endpoint. Reading statuses is allowed. A context left to a variable
(`-f context="$CTX"`) is denied too, since the guard cannot tell which status it sets.

**Red tests (M tickets, [#191](https://github.com/Sycatle/senior-mode/issues/191)).** A separate
`test-author` session writes and commits the failing tests, then `senior-mode red-tests record <n>`
lists them in `.git/senior-mode/runs/<n>/red-tests`. In a session with `SENIOR_MODE_ROLE=ticket`, on a
branch named `<type>/<n>-slug` with such a list, `self-protect.sh` (which then acts even outside a
run) denies Edit, Write, MultiEdit and NotebookEdit on a listed file, and the Bash commands that
write, move or delete one (redirections, `tee`, `rm`, `mv`, `cp`, `sed -i`, `truncate`, `git rm`,
`git mv`, `git checkout`, `git restore`, the same way as the self-protection above), a directory that
holds one included, and the list itself. The implementer may add tests of its own. A red test that is
wrong stays as it is: the pull request says so and a human decides, and the review checks that the
red tests still pass unchanged.

Limits, as for the other guards: a guardrail for honest mistakes, not a sandbox. `bash -c "..."`,
`eval`, scripts, a variable that stands for a whole path or endpoint, `python -c` and an editor
started from Bash are not read, so a determined session can change a red test or post a status; the
branch protection and the review of the pull request are the backstop (a changed red test shows in
the diff). The ticket is read in the branch name of the session's directory: a `cd` to another worktree
in the same command is not followed. The roles are set by whoever starts the session, and the serve
loop that starts `test-author` and `reviewer` sessions comes with [#149](https://github.com/Sycatle/senior-mode/issues/149):
until then `run` starts ticket sessions without a role, which still review and set the status
themselves as described in [Run](#run). A reviewer that runs as a subagent of the ticket session
shares its environment, so it cannot post the status once the role is `ticket`: that is the point
of the separate session.

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
- **Collisions:** tickets whose board field Paths overlap never run at the same time, and a ticket
  with no Paths runs alone: nothing else starts while it runs. Two Paths overlap when a glob of one
  matches a path prefix of the other (`src/a/**` and `src/a/x.ts`), or is the same glob; a ticket
  that has to wait lets the next one start, in `pick` order. The check needs the field: a config
  from before it existed (no `Paths` in `project.fields`) runs tickets in parallel as before, until
  `senior-mode setup github` is rerun.
- **Batches:** `senior-mode pick` groups Ready S tickets whose Paths overlap, at most 3 per batch
  (and `limits.prLines` / 50, an S being about 50 lines); M and L tickets and tickets without Paths are
  never batched. The target is one session and one pull request per batch, one commit and one
  `Closes #n` per ticket; `run` does not start a batch that way yet (#263), it still starts the
  tickets one by one.
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
  stays In progress; the label is the signal. A session script that dies without leaving its exit
  file (killed from outside) is noticed at the next poll, not at the timeout, and handled the same
  way with the reason `the session ended without leaving its exit code`; the poll never sleeps past
  the timeout. Background sessions are started with `setsid`, or with
  perl's `POSIX::setsid` where `setsid` is missing (macOS). With neither, `run` starts nothing and says
  so, even when tmux is installed: the docs session below is always a background session, and `run`
  could not stop it if it got stuck. A process that left the group on its own is the one thing `run`
  may not stop: it says so, and still labels and records the ticket.
  The docs session that follows merges is bounded by the same timeout and killed the same way. It has
  no ticket, so nothing is labelled: `run` says so on stderr and in its report, and records the outcome
  in `docs-outcome.json` next to the ticket records (`retro` does not read it). Its branch and worktree
  (`~/.local/share/senior-mode/worktrees/<repo>/run-docs-<stamp>`) are kept, and `run` ends normally.
- **Window that does not start:** if tmux cannot start the window of a session (the first one or the
  retry on Opus), the ticket fails at once instead of waiting for the timeout: `needs-human`, a comment
  with the path of tmux's error output, a `failed` record, one failure for the circuit breaker.
- **Guards at the start** (with the `claude` CLI): `run` refuses to start unless the plugin is enabled
  for ticket sessions and its `hooks/hooks.json` is present. Ticket sessions run in fresh worktrees of
  the default branch, so only `enabledPlugins` in the user settings (`~/.claude/settings.json`, or
  `CLAUDE_CONFIG_DIR`), in the `.claude/settings.json` committed on the default branch and in the
  managed settings (`/etc/claude-code/managed-settings.json`, or the macOS equivalent, which win) count,
  not an untracked `settings.local.json`; a plugin loaded with `--plugin-dir` counts. Once a day it also
  runs a short probe session (Haiku), in a throwaway worktree of the default branch, asked to run
  `git -c core.hooksPath=... init` on a temporary directory, a command the Bash guard denies and that
  is harmless if it is not denied. If the deny does not show in the session's output, or the
  directory was created, `run` starts nothing and says so; the output is in
  `.git/senior-mode/probe.log`. The date of the last pass is in `.git/senior-mode/probe`. The probe is
  stopped after 5 minutes (`SENIOR_MODE_PROBE_TIMEOUT`, in seconds), on every platform: a probe that
  does not answer counts as failed. Where `setsid` exists it runs in a process group of its own, killed
  with everything it started on a timeout, Ctrl-C or TERM, which also remove its worktree. A failed
  probe is recorded in `.git/senior-mode/probe-failed`; for the next hour
  (`SENIOR_MODE_PROBE_RETRY`, in seconds) `run` refuses to start without starting another probe
  session, then probes again. Under another `agent.command` none of this runs: those hooks do
  not hold there anyway.
- **Proof:** a session counts as delivered only if a pull request is open for its branch.
- **Merge** ([ADR 0008](../adr/0008-merge-off-by-default.md)): off by default. With
  `autonomy.merge: true`, a pull request merges (`gh pr merge --rebase`) only when `senior-mode/ci`,
  `senior-mode/review` and `senior-mode/security` are all `success` on its head, it has no `needs-human` label, the
  server enforces protection (`github.protection` is `ruleset`), and none of its files matches a
  protected zone of the default branch: `run` checks that itself, it does not rely on the reviewer.
  The merge names the head it checked (`--match-head-commit`), so a later push is refused.
  Everything else waits for a human, and the report says why. The ticket session itself never
  merges: the Bash guard denies it any merge. When the pull request merges but the ticket's Status
  cannot be set Done, the report lists it under `Status not set to Done`, and `status` shows it as drift.
- **Hygiene:** `run` calls `senior-mode clean` when it starts, before it looks at the board, and when it
  ends if it ran tickets (see [Hygiene](#hygiene)). A failing `clean` is reported on stderr and does not
  stop the run.
- **Agent:** the headless CLI is `agent.command` (default `claude`), for the tickets and the docs
  session, scheduled or not. Another compatible CLI, such as syacode, can replace it, but senior-mode's
  hooks and guards do not hold under it until it implements them (Sycatle/syacode#13 to #18): use it
  only on a machine where that is acceptable.
- **End-to-end suites** share `e2e.slots` slots per machine (default 2): `check` runs the check named
  `e2e` through `senior-mode e2e-lock`, which exports the slot number as `SENIOR_MODE_E2E_SLOT`. The lock files live in `$XDG_RUNTIME_DIR/senior-mode-e2e`, else in
  a private `senior-mode-e2e-<uid>` directory of `$TMPDIR` (or `/tmp`); a directory that is a link, not yours or not
  mode 0700 is refused.

### Hygiene

`senior-mode clean [--dry-run] [--days N]` removes what is finished, so worktrees and branches do not
pile up. It runs by itself at the start and the end of a `run` and after the report of
`senior-mode status --fix`, and on demand. What is merged or closed comes from the pull request on
GitHub, never from git ancestry, so squash and rebase merges are handled.

- **Removed:** the worktrees, wherever they are (beside the repository, under `.git/senior-mode/worktrees`
  or in the data directory: they are read from `git worktree list`), and the local branches whose pull
  request is merged or closed, or whose ticket is closed and that has no pull request; the remote
  branches whose pull request was merged or closed more than N days ago, if their tip is still the
  head of that pull request; the run directories (`.git/senior-mode/runs/<stamp>`, with their logs,
  records and token files) and the `probe` and `probe.log` files with no activity for N days; then
  `git worktree prune`. N is `--days`, else `hygiene.days` (default 14). `retro` reads the run records,
  so a `--since` longer than N days sees fewer runs.
- **Kept, and listed with the reason** (the exit status stays 0): a worktree with uncommitted changes
  (untracked files count); a branch whose commits are on no remote branch, not in the default branch
  and not in its pull request (a merged pull request whose branch GitHub deleted still holds them);
  a locked worktree; a branch or remote branch of a ticket In progress on the board.
- **Never deleted, locally or on origin:** only the branches `start` and `frame start` make are
  candidates (`feat/<n>-...`, `fix/<n>-...`, `chore/<n>-...`, and `docs/<slug>` or `docs/run-<stamp>`:
  lower-case letters, digits and single hyphens, 40 characters at most). A `dev`, a `staging`, a
  `release/*` or a `docs/next.v2` whose pull request merged long ago is listed
  (`not a branch senior-mode makes`) and kept.
  So is the base of any pull request, open, closed or merged (deleting it would close the pull
  requests stacked on it), a protected branch (the list GitHub gives for the repository, rulesets
  included) and the default branch.
- **Never touched:** the main worktree, the current one and the branches they have checked out, a
  branch with an open pull request.
- **`--dry-run`** prints each line as `would remove ...` and changes nothing. A real run prints
  `removed ...`. If GitHub or the board cannot be read, `clean` stops before removing anything.
- **Before it decides, `clean` runs `git fetch --prune origin`**, also under `--dry-run`: it only moves
  the remote-tracking refs, never a branch or a work tree, and without it a tracking ref of a branch
  deleted on origin would make its commits look pushed. If the fetch fails (no ssh agent in a
  scheduled run), `clean` says so and treats "pushed" as unknown: a branch is then kept unless its
  commits are in the default branch or in its pull request. If the list of protected branches cannot
  be read, it says so and keeps every `docs/` branch (a ticket's branch stays a candidate).
- **What is lost with a removed worktree:** its ignored files (`node_modules`, `.env`, build output)
  go with it; `start` reinstalls the dependencies of a new one. Commits are not lost: a pull request
  closed without merging keeps its commits on GitHub at `refs/pull/<N>/head`, and
  `git fetch origin pull/<N>/head:<branch>` brings them back as a branch.

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
