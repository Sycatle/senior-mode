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
| `language` | `en` | Language of the templates (`en` or `fr`) and of what Claude writes for you; setup does not write it, add it yourself |
| `preset` | detected | `node` with a `package.json`, else `go`, `rust` or `python` from their manifest, else `generic`; a stored value wins |
| `commands` | detected or asked | `lint`, `typecheck`, `test`, `build`, and `e2e` for node; `format` for python and rust; `install` (no check), the command `senior-mode start` runs in a new worktree: the lockfile's `npm ci`, `pnpm install --frozen-lockfile`, `yarn install --frozen-lockfile` or `bun install --frozen-lockfile` for node, `uv sync` or `poetry install` for python, `go mod download`, `cargo fetch`; change it with `setup repo --command install=...` |
| `framework` | none | `next` when Next.js is a dependency; the node preset then adds `middleware.*`, `src/middleware.*`, `proxy.*` and `src/proxy.*` to `protected` |
| `envGuard.forbidden` | none | Strings, or `/regex/` patterns, that must never appear on an agent machine; turns on the `env guard` check |
| `checks` | from `commands` | The check list: `{ "name", "run" }` entries, run in order |
| `protected` | preset's globs | Globs of [protected zones](autonomy.md#protected-zones): setup writes the preset's list (plus the framework's, for Next.js) when the key is absent and keeps yours, even an empty one; `senior-mode protected` and the reviewer read it |
| `ci.mode` | `local` | `local` or `actions` |
| `secrets` | none | Extra globs the [secrets guard](autonomy.md#secrets-guard-guard-secretssh) denies, added to its defaults: `"*.token"` matches a file name anywhere, `"config/prod.*"` and `"**/vault/*"` match from the repository root. It never allows a default. Add it yourself; setup does not write it |
| `github.protection` | written by setup | `ruleset` when the `senior-mode` ruleset protects the default branch, `none` when GitHub refused it (private repository on a Free plan): the branch is then not protected on the server |
| `review.sections` | none | Project review checklists, see [below](#project-review-sections) |
| `project` | written by setup | Board owner, number, id, and field and option ids, so no agent looks them up again |
| `docs.extra` | none | Extra living documents the `docs` skill keeps current after a merge: a list of `{ "path", "purpose" }`; its changes are flagged for human review. Add it yourself |
| `autonomy.maxTickets` | `3` | Tickets per [run](autonomy.md#run) |
| `autonomy.parallel` | `1` | Tickets a run works on at once |
| `autonomy.maxConsecutiveFailures` | `2` | Failed tickets in a row after which a run starts no new one |
| `autonomy.merge` | `false` | Whether a run merges the pull requests that pass every bound |
| `autonomy.escalate` | `true` | Whether a ticket that fails on Sonnet is retried once on Opus |
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
- `senior-mode check` prints `ok`, `skip` or `FAIL` per check, with the last 20 lines of a failure.
  A check whose first output line is `skipped: <reason>` passes and prints `skip <name>: <reason>`,
  so a check that had nothing to do is visible instead of a silent `ok`.
- A node project that declares dependencies but has no `node_modules` fails at once with
  `dependencies not installed: run <install command>`, before any check runs.
- When `envGuard.forbidden` lists something, setup adds the `env guard` check (below).

Not in the list yet: spec drift ([v0.2](https://github.com/Sycatle/senior-mode/milestone/2)) and
secret scanning (planned in spec §14, no milestone yet). You can add your own as a check entry.

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
