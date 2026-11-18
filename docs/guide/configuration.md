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
  "ci": { "mode": "local" },
  "project": { "owner": "acme", "number": 3, "id": "PVT_...", "fields": { "Status": { "id": "...", "options": { "Ready": "..." } } } }
}
```

### Keys the plugin reads today

| Key | Default | Used for |
|---|---|---|
| `language` | `en` | Language of the templates (`en` or `fr`) and of what Claude writes for you; setup does not write it, add it yourself |
| `preset` | detected | `node` with a `package.json`, else `generic`; a stored value wins |
| `commands` | detected or asked | `lint`, `typecheck`, `test`, `build`, and `e2e` for node |
| `framework` | none | `next` when Next.js is a dependency (recorded only) |
| `checks` | from `commands` | The check list: `{ "name", "run" }` entries, run in order |
| `ci.mode` | `local` | `local` or `actions` |
| `project` | written by setup | Board owner, number, id, and field and option ids, so no agent looks them up again |

`senior-mode config get <key>` prints a value, with dots for nested keys (`ci.mode`).

### Keys with defaults but no effect yet

`autonomy.maxTickets` (3), `autonomy.parallel` (1), `autonomy.maxConsecutiveFailures` (2),
`autonomy.autoMerge` (true) and `limits.prLines` (400) can be read, but only `run` will use them
([v0.3](https://github.com/Sycatle/senior-mode/milestone/3)). The `protected` key of the spec is
not written by setup and has no default yet ([v0.3](https://github.com/Sycatle/senior-mode/milestone/3)).

## Checks

The check list is the one list of things that must pass. The `pre-push` hook, `senior-mode check`
and, in `actions` mode, the workflow all run it, from the repository root.

- Setup derives one check per stored command, named after it, in the order lint, typecheck, test,
  build, e2e.
- It adds `commit subjects` (every commit of the branch is a Conventional Commit) when the
  `commit-msg` hook is senior-mode's own.
- Checks you add by hand are kept on re-run. `senior-mode setup repo --command test="npm test"`
  replaces the command of the check with the same name.
- `senior-mode check` prints `ok` or `FAIL` per check, with the last 20 lines of a failure.

Not in the list yet: spec drift ([v0.2](https://github.com/Sycatle/senior-mode/milestone/2)) and
secret scanning (planned in spec §14, no milestone yet). You can add your own as a check entry.

## CI mode

| `ci.mode` | What setup does |
|---|---|
| `local` | Disables the repository's workflows on GitHub (files kept). Checks run before each push; `senior-mode publish` sets `senior-mode/ci`. |
| `actions` | Adds `.github/workflows/senior-mode.yml`: on pull requests and pushes to the default branch, it installs dependencies (with caching), runs the checks, sets `senior-mode/ci`, runs a dependency review, and releases (below). Re-enables it if `local` disabled it before. |

Switch with `senior-mode setup github --ci actions` (or `local`), then `senior-mode setup repo`.
Your other workflows stay as they are in `actions` mode; turn one back on with `gh workflow enable <name>`.

## Presets

| Preset | State | Commands |
|---|---|---|
| `node` | Available | Your `package.json` scripts (`lint`, `typecheck` or `type-check`, `test`, `build`, `test:e2e` or `e2e`), run with the package manager of your lockfile (npm, pnpm, yarn, bun). With a `tsconfig.json`, no typecheck script and `typescript` installed: `tsc --noEmit`, never downloaded. npm's placeholder test script does not count. |
| `generic` | Available | Asked once, then stored |
| `python`, `go`, `rust` | Coming in [v0.4](https://github.com/Sycatle/senior-mode/milestone/4) | |

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
ask when a decision is open. Re-running setup refreshes the block; edit outside it. Without a
`CLAUDE.md`, setup creates a skeleton (commands, code map, pitfalls) that Claude fills from the code.
Setup warns when the file goes over 80 lines.

## Releases (release-please)

Setup writes `release-please-config.json` (release type `node` or `simple`) and
`.release-please-manifest.json`, both only if absent. A new project starts at 0.1.0; a
`package.json` version counts as the last release, so the next release bumps it.

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
