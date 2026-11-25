# Running the pipeline on a server

How to run `senior-mode serve` and its agent sessions unattended on a server you own (a VPS, a spare
machine), for one or several repositories. It is what the first production pilot needed, in the order it
is done. [Getting started](getting-started.md) covers the plugin itself; [Autonomy](autonomy.md#run)
covers what `serve` does once it runs.

## What runs where

- One Linux account, with no sudo, runs Claude Code, the plugin and every daemon. The agents can then
  change nothing outside that account.
- `root` owns the Claude Code managed settings: the pinned plugin version, the sandbox and the deny rules.
  The agents cannot loosen them.
- One `serve` daemon per repository, as a systemd user unit. It polls the board every minute, starts
  ticket sessions (Sonnet) in worktrees, review sessions (Opus), and merges what the three statuses allow.
- GitHub is the only state that matters: the board, issues, pull requests and statuses. A lost server
  loses running sessions, not work that was pushed.

## 1. The account

```bash
# as root
adduser --disabled-password agent
loginctl enable-linger agent   # user units and tmux survive logout
```

Install as that user: Claude Code (`claude`, signed in), `git`, `gh`, `jq`, `tmux`, and the project
toolchains (a version manager such as mise keeps them per user). Clone over HTTPS.

A shell opened with `su - agent` has no `XDG_RUNTIME_DIR`: export `XDG_RUNTIME_DIR=/run/user/$(id -u)`
before `systemctl --user`.

## 2. The plugin, pinned by root

In `/etc/claude-code/managed-settings.json`, pin the marketplace to a commit and force the plugin on, so
an agent cannot swap or disable it:

```json
{
  "extraKnownMarketplaces": {"senior-mode": {"source": {"source": "github", "repo": "Sycatle/senior-mode", "ref": "<sha>"}}},
  "strictKnownMarketplaces": [{"source": "github", "repo": "Sycatle/senior-mode", "ref": "<sha>"}],
  "enabledPlugins": {"senior-mode@senior-mode": true}
}
```

Link the CLI for use outside Claude: `ln -s ~/.claude/plugins/marketplaces/senior-mode/plugins/senior-mode/bin/senior-mode ~/.local/bin/`.
Upgrading is replacing `<sha>` in both places, `git checkout <sha>` in that marketplace checkout, and
restarting the units. Keep a dated backup of the settings each time.

## 3. Sandbox and permissions of the sessions

`serve` starts sessions with `--permission-mode bypassPermissions`: the managed settings must not set
`disableBypassPermissionsMode`. What keeps them safe is the sandbox and the deny list, which bypass does
not lift:

- `sandbox.enabled: true`, `allowUnsandboxedCommands: false`, and `excludedCommands` for `gh` and the git
  network commands (`git push`, `git fetch`, `git pull`).
- `sandbox.filesystem.allowRead` for what a session needs from the home directory: the toolchains, the git
  config and signing key, the package manager config. A sandboxed session sees an almost empty home:
  without these it has no node, no git identity and cannot commit.
- `sandbox.filesystem.allowWrite` for the package caches (`~/.npm`, the toolchain caches).
- `sandbox.network.allowedDomains`: `api.github.com` (a `gh` inside a pipe runs sandboxed) and the
  package registries the project installs from.
- `permissions.deny`: pushes to the default branch (`Bash(git push * main)` and its variants),
  `gh auth token`, `gh auth login|logout|refresh|switch`, `gh secret`, `gh repo delete|edit`, `sudo`,
  `su`, `ssh`, `curl`, `wget`, and reads of `~/.ssh`, `~/.config/gh` and any secrets directory. Leave
  `gh auth status` allowed: sessions check it, and conclude they are logged out when it is denied.

The sandbox keeps `.git/worktrees` read-only: senior-mode needs no write there from a session.

## 4. The GitHub token

`serve` and the sessions use `GH_TOKEN`. A fine-grained personal access token is scoped to **one owner**
(a user or an organization): the same token serves every repository of that owner, and a repository of
another owner needs its own. Give it access to the served repositories, with:

| Permission | Access | Used by |
|---|---|---|
| Contents | Read and write | branches, pushes |
| Pull requests | Read and write | opening, reviewing, merging |
| Issues | Read and write | tickets, labels, comments |
| Commit statuses | Read and write | `senior-mode/ci`, `review`, `security` |
| Actions | Read and write | `setup github --ci local` disables workflows |
| Administration | Read and write | `setup github`: ruleset, merge settings (else set them by hand) |
| Projects (organization or account) | Read and write | the board |
| Secret scanning alerts, Dependabot alerts | Read | alerts read by `serve` (optional) |

A fine-grained token cannot read check runs; senior-mode reads the board without them.

Keep it in a file only the account reads, outside every repository, for example
`~/.config/senior-mode/serve.env` (mode 600), next to `SENIOR_MODE_NOTIFY_WEBHOOK` if you want alerts
pushed to you:

```
GH_TOKEN=github_pat_…
SENIOR_MODE_NOTIFY_WEBHOOK=https://…
```

## 5. Adopting a repository

In the clone, run `claude` then `/senior-mode:setup` (see [Getting started](getting-started.md#adopt-a-repository)).
Then check what an unattended run depends on:

- `.claude/settings.json` is **committed** and enables `senior-mode@senior-mode`: ticket sessions run in
  fresh worktrees and see only committed files. `serve` refuses to start sessions otherwise.
- Every command in `commands` runs with no secret. A build that needs environment variables gets a
  committed file of dummy values (hosts under `.invalid`) that only the check loads.
- The git identity of the account matches the token's user (its noreply address if the account hides its
  email), or GitHub refuses the push.
- `senior-mode check` passes on a clean tree.

## 6. The board

- Keep GitHub's default **`Todo`** status option and never add one named `Backlog`: on some
  organizations an option named `Backlog` makes GitHub put every issue back to it about a second after
  each move. senior-mode reads `Todo` as Backlog. To test a board: move an issue to In progress and read
  its Status five seconds later. See the [FAQ](faq.md#my-tickets-jump-back-to-backlog-after-every-move-why).
- In the Project's built-in workflows, turn off *Item added to project* and *Pull request linked to
  issue*: they write the Status while `serve` does. Keep *Item closed* and *Pull request merged*.
- A review session reads the config of the pull request's branch: after you change the board, rebase the
  open pull requests, or tickets they file land on the old board.

## 7. One unit per repository

`senior-mode serve --install` writes a single `senior-mode-serve.service` per machine, without your
proxy or toolchain paths. On a server, write a template unit once,
`~/.config/systemd/user/senior-mode-serve@.service`:

```ini
[Unit]
Description=senior-mode serve (%i)
After=network-online.target

[Service]
Environment=PATH=%h/.local/share/mise/shims:%h/.local/bin:/usr/local/bin:/usr/bin:/bin
EnvironmentFile=%h/.config/senior-mode/serve.env
EnvironmentFile=%h/.config/senior-mode/repos/%i.env
ExecStart=/bin/bash -c 'cd "$SENIOR_MODE_REPO" && exec senior-mode serve'
Restart=on-failure
RestartSec=60
KillMode=mixed
TimeoutStopSec=660

[Install]
WantedBy=default.target
```

Add an `EnvironmentFile=` for a proxy if the server has one. `TimeoutStopSec` is `serve.grace` plus a
minute. Then, per repository:

```bash
mkdir -p ~/.config/senior-mode/repos
echo "SENIOR_MODE_REPO=$HOME/work/<owner>/<repo>" > ~/.config/senior-mode/repos/<repo>.env
chmod 600 ~/.config/senior-mode/repos/<repo>.env   # a GH_TOKEN of another owner goes here
systemctl --user daemon-reload
systemctl --user enable --now senior-mode-serve@<repo>.service
```

Session slots are counted per repository: `autonomy.parallel` of 8 in two repositories is up to 16
sessions at once. Split the budget the machine can hold in `.claude/senior-mode.local.json` of each clone,
for example `{"autonomy": {"parallel": 4}}`.

## 8. The first cycle

File a small ticket with clear acceptance criteria and set it Ready:

```bash
senior-mode issue create --title "…" --body-file body.md --size S --priority "P1 next" --type task --paths "…" --status Ready
journalctl --user -u senior-mode-serve@<repo> -f
```

Expected: `session started on sonnet`, then `reviewing pull request #N on opus`, then
`senior-mode/review is success`, then `Merged: #…`. The ticket ends Done and the issue closed. A
feature or bug ticket also runs a test-author session first.

## Operations

| Need | Command |
|---|---|
| Where things stand | `senior-mode status` in the clone |
| Logs | `journalctl --user -u senior-mode-serve@<repo> --since -1h` |
| Lift a pause | `senior-mode serve --resume` in the clone |
| Stop | `systemctl --user stop senior-mode-serve@<repo>` (sessions get `serve.grace` to finish) |
| Watch sessions | `tmux attach -t senior-mode-run` |
| A session's outcome | `.git/senior-mode/serve/<issue>.outcome` and `<issue>-<model>.json` |

A ticket labelled `needs-human`, or whose body leaves a decision open, waits for you: decide in the body,
remove the label, set it Ready again.

## Several repositories and organizations

Today each repository is served on its own: its board, its daemon, its config. One Project and one
daemon for a product of several repositories, cross-repository epics, and configuration inherited from
the organization are planned for v1.4 (epic #329,
[spec 329](../specs/329-multi-repo-products.md)). Until then, one unit per repository as above, and one
token per owner.
