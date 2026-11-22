# Configuration

How `.claude/senior-mode.json`, the checks, the CI mode, presets, git hooks, `CLAUDE.md` and releases are set up.

`setup` writes all of this; you rarely edit it by hand. Re-run `/senior-mode:setup` after a change
to repair anything it owns. The design is in [spec §13](../specs/0001-senior-mode.md#13-project-config)
and [§14](../specs/0001-senior-mode.md#14-stack-presets-and-ci).

## `.claude/senior-mode.json`

An example written by setup for a JavaScript Next.js project using pnpm:

```json
{
  "preset": "node",
  "framework": "next",
  "commands": { "lint": "pnpm run lint", "test": "pnpm run test", "build": "pnpm run build" },
  "checks": [
    { "name": "lint", "run": "pnpm run lint" },
    { "name": "test", "run": "pnpm run test" },
    { "name": "build", "run": "pnpm run build" },
    { "name": "commit subjects", "run": ".githooks/commit-msg --branch" }
  ],
  "protected": ["**/migrations/**", "**/auth/**", ".github/workflows/**", "Dockerfile*"],
  "ci": { "mode": "local" },
  "project": { "owner": "acme", "number": 3, "id": "PVT_...", "fields": { "Status": { "id": "...", "options": { "Ready": "..." } } } }
}
```

### Keys the plugin reads today

| Key | Default | Used for |
|---|---|---|
| `language` | `en` | Language of the templates (`en` or `fr`) and of what Claude writes for you; setup proposes the language of your `CLAUDE.md` or conversation and writes it before the templates |
| `preset` | detected | `node` with a `package.json`, else `go`, `rust` or `python` from their manifest, else `generic`; a stored value wins |
| `commands` | detected or asked | `lint`, `typecheck`, `test`, `build`, and `e2e` for node; `format` for python and rust; `install` (no check), the command `senior-mode start` runs in a new worktree: the lockfile's `npm ci`, `pnpm install --frozen-lockfile`, `yarn install --frozen-lockfile` or `bun install --frozen-lockfile` for node, `uv sync` or `poetry install` for python, `go mod download`, `cargo fetch`; change it with `setup repo --command install=...` |
| `framework` | none | `next` when Next.js is a dependency; the node preset then adds `middleware.*`, `src/middleware.*`, `proxy.*` and `src/proxy.*` to `protected` |
| `envGuard.forbidden` | none | Strings, or `/regex/` patterns, that must never appear on an agent machine; turns on the `env guard` check |
| `checks` | from `commands` | The check list: `{ "name", "run" }` entries, run in order |
| `protected` | preset's globs | Globs of [protected zones](autonomy.md#protected-zones): setup writes the preset's list (plus the framework's, for Next.js) when the key is absent and keeps yours, even an empty one; `senior-mode protected` and the reviewer read it, and `setup github` maps it to [CODEOWNERS](autonomy.md#code-owners) |
| `ci.mode` | `local` | `local` or `actions` |
| `audit` | `true` | `false` turns off the [dependency audit](#dependency-audit) of `check`; `status` then says so. Set it yourself, setup does not write it |
| `secrets` | none | Extra globs the [secrets guard](autonomy.md#secrets-guard-guard-secretssh) denies, added to its defaults: `"*.token"` matches a file name anywhere, `"config/prod.*"` and `"**/vault/*"` match from the repository root. It never allows a default. Add it yourself; setup does not write it |
| `github.protection` | written by setup | `ruleset` when the `senior-mode` ruleset protects the default branch, `none` when GitHub refused it (private repository on a Free plan): the branch is then not protected on the server |
| `review.sections` | none | Project review checklists, see [below](#project-review-sections) |
| `project` | written by setup | Board owner, number, id, and field and option ids, so no agent looks them up again |
| `docs.extra` | none | Extra living documents the `docs` skill keeps current after a merge: a list of `{ "path", "purpose" }`; its changes are flagged for human review. Add it yourself |
| `wip` | `1` | Open tickets In progress at once: `senior-mode start` refuses another and names the one to finish first; `status` shows the count when it is over. A [run](autonomy.md#run) is bounded by `autonomy.parallel` instead, and is the only caller that skips `wip`: it proves itself with a token, so setting `SENIOR_MODE_RUN=1` by hand does not |
| `autonomy.maxTickets` | `3` | Tickets per [run](autonomy.md#run) |
| `autonomy.parallel` | `1` | Tickets a run works on at once |
| `autonomy.maxConsecutiveFailures` | `2` | Failed tickets in a row after which a run starts no new one |
| `autonomy.merge` | `false` | Whether a run merges the pull requests that pass every bound |
| `autonomy.escalate` | `true` | Whether a ticket that fails on Sonnet is retried once on Opus |
| `autonomy.sessionTimeout` | `90` | Minutes a ticket session may run (a whole number from 1 to 1440). Past it, a [run](autonomy.md#run) kills the session (its process group), labels the ticket `needs-human` with the log path, counts a failure for the circuit breaker and does not retry on Opus; the ticket's Status is left as it is. The docs session after merges is bounded by the same limit |
| `autonomy.schedule` | `"02:00"` | Time of day (`HH:MM`) of the [scheduled run](autonomy.md#scheduled-runs), unless `senior-mode schedule install --at` says otherwise |
| `agent.command` | `claude` | The headless CLI `run` starts for each ticket and for the docs session, on `PATH` or in `~/.local/bin`; the guards of senior-mode do not hold under another CLI until it supports them (see [Run](autonomy.md#run)) |
| `e2e.slots` | `2` | End-to-end suites that may run at once on the machine (the check named `e2e`) |

`senior-mode config get <key>` prints a value, with dots for nested keys (`ci.mode`). The optional keys
(`protected`, `secrets`, `envGuard.forbidden`, `review.sections`, `docs.extra`, `github.protection`)
print `[]` (an empty line for `github.protection`) when absent; a key the plugin does not know is an error.

### Keys with defaults but no effect yet

`limits.prLines` (400) can be read, but nothing uses it yet.

## Project review sections

`review.sections` is a list of Markdown checklist files, relative to the repository root. The
`review` skill reads each one and applies it as an extra section of its review. This is where a
project puts checks the plugin cannot know: a regulated activity, a stack, a company rule.

```json
{ "review": { "sections": ["docs/review/payments.md", "docs/review/api.md"] } }
```

```markdown
# Payments

Apply when the diff touches `src/billing/`.

- Amounts are integers in cents, never floats.
- Every webhook handler verifies the signature before reading the body.
- A new provider call has a timeout and a retry that cannot charge twice.
```

- Write each file as a checklist a reviewer can answer from the diff, with the condition for
  applying it on top. Findings come out in the review comment like any other.
- The reviewer reads the files from the base branch, so a pull request cannot weaken its own checks;
  a section file added or changed by the pull request applies from the next one.
- A missing file is reported by the review, not skipped silently. A section adds checks; it does not
  lift the rule for protected zones.
- Setup does not write this key. Add it by hand; without it, no extra section applies.

## Checks

The check list is the one list of things that must pass. The `pre-push` hook, `senior-mode check`
and, in `actions` mode, the workflow all run it, from the repository root.

- Setup derives one check per stored command, named after it, in the order lint, typecheck, test,
  build, e2e.
- It adds `commit subjects` (every commit of the branch is a Conventional Commit) when the
  `commit-msg` hook is senior-mode's own.
- Checks you add by hand are kept on re-run. `senior-mode setup repo --command test="npm test"`
  replaces the command of the check with the same name.
- `senior-mode check` prints `ok`, `skip` or `FAIL` per check, with the last 20 lines of a failure (the dependency audit shows every blocking advisory, up to 100).
  A check whose first output line is `skipped: <reason>` passes and prints `skip <name>: <reason>`,
  so a check that had nothing to do is visible instead of a silent `ok`.
- A node project that declares dependencies but has no `node_modules` fails at once with
  `dependencies not installed: run <install command>`, before any check runs.
- When `envGuard.forbidden` lists something, setup adds the `env guard` check (below).
- `check` starts with two built-in steps that are not in the list: the `secret scan`, which cannot be
  turned off, and the `dependency audit`, which `audit: false` turns off (both below). A passing check
  that has warnings prints them under its `ok`.

Not in the list yet: spec drift (planned, no milestone yet). You can add your own as a check entry.

### Secret scan

`senior-mode check` reads the lines your branch adds (`git diff <base>...HEAD`, the base being the
default branch) and fails on a provider key (AWS, GitHub, GitLab, npm, Stripe, Slack, Google, OpenAI,
Anthropic, SendGrid, Azure storage), a JWT, a URL with credentials (`scheme://user:password@host`, the
user may be empty: `redis://:password@host`), a private key, or a value of 16 characters or more
assigned to a name such as `password`, `secret`, `token` or `api_key`. That last kind is a heuristic,
not an entropy measure: the value needs a letter and a digit, and placeholders, brackets and dotted
identifiers (`process.env.TOKEN_1`) are left alone. In a URL, the password is a placeholder only when
it has five characters or fewer, is a template (`${X}`, `<x>`, `%s`, `***`) or equals a word such as
`password`, `changeme` or `test` once digits and punctuation are dropped; a password that merely
contains `test` or `%` is reported. The scan prints `file:line: kind` and never the value. The patterns
are in `plugins/senior-mode/secret-patterns`.
Without a default branch to compare with, the scan shows as `skip`.

A false positive is lifted by a human: add `<sha256 of the value> <reason>` to
`.claude/secret-allowlist` and merge that change first (compute the hash with
`printf %s '<value>' | sha256sum`). The value is the key, token or password itself, without the name or
quotes; for a URL it is the whole URL, and for a private key the whole block from the `BEGIN` line to the
`END` line, so `printf %s "$(cat key.pem)" | sha256sum` for a file that holds only the key. An entry
lifts that value and nothing else. The file is read from the base branch, so a pull request cannot
allowlist its own secret; `setup` adds it to `protected`, and agents in a run cannot write it.

The scan reads the net diff of the branch. A secret added in one commit and deleted in a later one is
already in the pushed history: rotate it, do not just delete it. It does not read binary files or
commits that are not part of `<base>...HEAD`.

### Dependency audit

`senior-mode check` runs the audit tool of the lockfile at the repository root, whatever the preset:

| Lockfile | Command | Install it with |
|---|---|---|
| `pnpm-lock.yaml` (before `package-lock.json`) | `pnpm audit --json` | `npm install -g pnpm` |
| `package-lock.json` | `npm audit --json` | Node.js |
| `requirements.txt` | `pip-audit -r requirements.txt -f json` | `pipx install pip-audit` |
| `go.sum` | `govulncheck -json ./...` | `go install golang.org/x/vuln/cmd/govulncheck@latest` |
| `Cargo.lock` | `cargo audit --json` | `cargo install cargo-audit --locked` |

A high or critical advisory fails the check and is printed as `critical: <package> <advisory>, fixed in
<version>`. An advisory of another severity, or with none, passes and is printed as a `warning:` line:
`pip-audit`, `govulncheck` (only the vulnerabilities your code calls) and `cargo audit` give no
severity, so Dependabot is the net for those. A missing tool fails the check and says how to install
it, and so does a tool that gives no usable answer (no network): nothing was audited. Without any of
these lockfiles the step shows as `skip`. Yarn, Bun, uv and Poetry lockfiles are not audited yet, and
only the repository root is looked at: a `go.sum`, `Cargo.lock` or `requirements.txt` in a
subdirectory is not audited (a root pnpm or npm lockfile covers its workspaces). `requirements.txt` is
not a lockfile: `pip-audit` resolves what is unpinned when it runs, so the result is for today's
resolution. A dependency `pip-audit` skips (a local path, `-e`, a package the index does not know) is a
`warning: not audited:` line.

Each tool runs under `timeout` (600 seconds, `SENIOR_MODE_AUDIT_TIMEOUT` changes it) when the machine
has it, and a tool that hangs fails the check saying it timed out; without `timeout`, nothing bounds it.

`"audit": false` turns the step off, and `senior-mode status` prints `Dependency audit: off` while it
is. Turning it off is a human's call.

### Environment guard

Agent machines use development environments only. Name what must never be there, and the check
enforces it:

```json
{ "envGuard": { "forbidden": ["db.prod.example.com", "prod-project-ref", "/acct-[0-9]{12}/"] } }
```

An entry is a literal string, or an extended regular expression between slashes. Run
`senior-mode setup repo` after adding the key: it copies `.githooks/env-guard.sh` (a script of your
own with that name is kept) and adds the `env guard` check. The check fails when an entry appears in
any `.env*` file under the repository (tracked or not, `.git` and `node_modules` left out) or in the
environment variables of the process that runs the checks. It prints file names, variable names and
line numbers, never a value or a pattern. Remove the key and the check shows as `skip`. It is not a
secrets scanner: it catches the production host, ref or account you listed, not any secret.

## CI mode

| `ci.mode` | What setup does |
|---|---|
| `local` | Disables the repository's workflows on GitHub (files kept). Checks run before each push; `senior-mode publish` sets `senior-mode/ci`. |
| `actions` | Adds `.github/workflows/senior-mode.yml`: on pull requests and pushes to the default branch, it installs dependencies (with caching), runs the checks, sets `senior-mode/ci`, runs a dependency review, and releases (below). Re-enables it if `local` disabled it before. |

Switch with `senior-mode setup github --ci actions` (or `local`), then `senior-mode setup repo`.
Your other workflows stay as they are in `actions` mode; turn one back on with `gh workflow enable <name>`.

When `github.protection` is `none` (private repository on GitHub Free), setup keeps or forces `local`:
the pre-push hook is the only gate, because nothing makes GitHub wait for the statuses. Upgrade or go
public, then run `senior-mode setup github` again to get the ruleset and `"ruleset"`; `ci.mode` stays
`local` until you pass `--ci actions`.

`setup github` also turns on Dependabot alerts, secret scanning and push protection where the plan
allows it. It turns on no Dependabot security updates and writes no `.github/dependabot.yml`; see [GitHub's scanners](autonomy.md#githubs-scanners).

## Presets

| Preset | State | Commands |
|---|---|---|
| `node` | Available | Next.js aware (see `framework`) with no separate preset. Your `package.json` scripts (`lint`, `typecheck` or `type-check`, `test`, `build`, `test:e2e` or `e2e`), run with the package manager of your lockfile (npm, pnpm, yarn, bun). With a `tsconfig.json`, no typecheck script and `typescript` installed: `tsc --noEmit`, never downloaded. npm's placeholder test script does not count. |
| `generic` | Available | Asked once, then stored |
| `python` | Available | From the tools the project uses: `ruff check .` or `flake8`; `black --check .` or `ruff format --check .`; `mypy .` or `pyright`; `pytest`; `python -m build` with a `[build-system]`. Prefixed with `uv run` (with `uv.lock`) or `poetry run` (with `poetry.lock`). Detected by `pyproject.toml`, `setup.py` or `requirements.txt`. |
| `go` | Available | `go vet ./...` (plus `golangci-lint run` when a `.golangci` config exists), `go test ./...`, `go build ./...`. Detected by `go.mod`. |
| `rust` | Available | `cargo clippy --all-targets -- -D warnings`, `cargo fmt --check`, `cargo test`, `cargo build`. Detected by `Cargo.toml`. |

When several match, `package.json` wins, then `go.mod`, `Cargo.toml` and the Python files. Each of the
python, go and rust presets also carries default `protected` globs (migrations, auth and security
directories, CI workflows, Dockerfiles and `infra/`; never lockfiles), used by the protected zones.

The node preset reports the language: TypeScript when `typescript` is a dependency or a tsconfig
exists, else JavaScript (no typecheck expected). A missing linter or test runner is reported, and
Claude proposes one (Biome, Vitest) in a separate commit, only on your yes.

## Git hooks

Setup copies two hooks to `.githooks/` and sets `core.hooksPath` to `.githooks`:

- `commit-msg` refuses a subject that is not `type(scope): subject`, with type among `feat`, `fix`,
  `docs`, `style`, `refactor`, `perf`, `test`, `build`, `ci`, `chore`, `revert`;
- `pre-push` runs the check list and stops the push if one fails.

They need only `bash`, `git` and `jq`. A hook of your own with the same name is kept. If
`core.hooksPath` already points elsewhere, setup leaves it and tells you to call the two hooks from there.

## `CLAUDE.md` Principles

Setup adds a `Principles` block between `<!-- senior-mode:principles -->` and
`<!-- /senior-mode:principles -->` markers: keep it simple, test first, atomic Conventional Commits,
one PR per issue of about 400 lines at most, decisions in `docs/adr/`, done means the checks pass,
agent machines use development environments only (`envGuard` enforces it when configured), ask when a
decision is open. Re-running setup refreshes the block; edit outside it. Without a
`CLAUDE.md`, setup creates a skeleton (commands, code map, pitfalls) that Claude fills from the code.
Setup warns when the file goes over 80 lines.

## Releases (release-please)

Setup writes `release-please-config.json` (release type `node` or `simple`) and
`.release-please-manifest.json`, both only if absent. A new project starts at 0.1.0; a version already
in `package.json`, `Cargo.toml` (`[package]`) or `pyproject.toml` (`[project]` or `[tool.poetry]`), or for
a Go module the latest `vX.Y.Z` tag, counts as the last release, so the next release bumps it.

```
senior-mode release --dry-run
senior-mode release
```

This runs release-please 17.11.2 through `npx` (Node 22 or later) with your `gh` token. It tags and
publishes a merged release pull request, then opens or updates the next one. Versions and
`CHANGELOG.md` come from your Conventional Commits ([ADR 0005](../adr/0005-rebase-and-release-please.md)).

### In `actions` mode

The workflow releases for you ([ADR 0006](../adr/0006-local-ci.md)): on each push to the default
branch, its `release` job runs the official release-please action with your
`release-please-config.json`. Do not run `senior-mode release` as well; both would race for the same
release.

By default the job uses the workflow's own token. GitHub then runs no workflow on the release pull
request it opens, so that pull request gets no `senior-mode/ci` status and cannot merge. Two ways
out:

- store a fine-grained token with Contents and Pull requests write access as the repository secret
  `RELEASE_PLEASE_TOKEN`; the job uses it when present, and its pull requests trigger the checks;
- or, on the release pull request, run `senior-mode check` and `senior-mode publish` yourself.

The job also needs GitHub Actions to be allowed to open pull requests (Settings > Actions > General)
unless the token secret is stored. `setup github --ci actions` warns when neither is the case.
