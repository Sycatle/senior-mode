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
| `language` | `en` | Language of the templates (`en` or `fr`) and of what Claude writes for you; setup proposes the language of your `CLAUDE.md` or conversation and writes it before the templates (`senior-mode setup answers --language`) |
| `preset` | detected | `node` with a `package.json`, else `go`, `rust` or `python` from their manifest, else `generic`; a stored value wins |
| `commands` | detected or asked | `lint`, `typecheck`, `test`, `build`, and `e2e` for node; `format` for python and rust; `install` (no check), the command `senior-mode start` runs in a new worktree: the lockfile's `npm ci`, `pnpm install --frozen-lockfile`, `yarn install --frozen-lockfile` or `bun install --frozen-lockfile` for node, `uv sync` or `poetry install` for python, `go mod download`, `cargo fetch`; change it with `setup repo --command install=...` |
| `framework` | none | `next` when Next.js is a dependency; the node preset then adds `middleware.*`, `src/middleware.*`, `proxy.*` and `src/proxy.*` to `protected` |
| `envGuard.forbidden` | none | Strings, or `/regex/` patterns, that must never appear on an agent machine; turns on the `env guard` check |
| `checks` | from `commands` | The check list: `{ "name", "run" }` entries, run in order |
| `protected` | preset's globs | Globs of [protected zones](autonomy.md#protected-zones): setup writes the preset's list (plus the framework's, for Next.js) when the key is absent and keeps yours, even an empty one; `senior-mode protected` and the reviewer read it, and `setup github` maps it to [CODEOWNERS](autonomy.md#code-owners) |
| `ci.mode` | `local` | `local`, `actions` or `existing` (the project's own CI is reused, see [CI mode](#ci-mode)) |
| `workflow.ci.jobs`, `workflow.ci.required` | detected | With `ci.mode` `existing`: the jobs of the project's CI that cover a check (`{ "context", "covers" }`, one per job) and its required status contexts; setup writes both, see [Following the project's workflow](#following-the-projects-workflow) |
| `workflow` | none | What `setup repo` detected of the project's branch model, commits, pull requests, merge method, labels and tracker, see [Following the project's workflow](#following-the-projects-workflow); absent, everything behaves as senior-mode's defaults |
| `adopt.kind` | detected | `evergreen` or `legacy`, from four signals (commits, age, source files, tests and lint); setup records it and a value you set is kept |
| `audit` | `true` | `false` turns off the [dependency audit](#dependency-audit) of `check`; `status` then says so. Set it yourself, setup does not write it |
| `security.minPackageAgeDays` | `30` | A dependency the branch adds fails `check` when its package was first published fewer days ago ([new dependencies](#new-dependencies)); a whole number from 1 |
| `security.minWeeklyDownloads` | `50` | A dependency the branch adds fails `check` when its package had fewer downloads last week; a whole number from 1 |
| `secrets` | none | Extra globs the [secrets guard](autonomy.md#secrets-guard-guard-secretssh) denies, added to its defaults: `"*.token"` matches a file name anywhere, `"config/prod.*"` and `"**/vault/*"` match from the repository root. It never allows a default. Add it yourself; setup does not write it |
| `data` | `*.sqlite`, `*.sqlite3`, `*.db`, `*.dump`, `*.bak`, `*.mdb`, `*.accdb` | Globs of business or production data (dumps, backups, exports) whose content the [secrets guard](autonomy.md#secrets-guard-guard-secretssh) denies, same syntax as `secrets`; listing them stays allowed. Setting it replaces the built-in list: add your dump folders (`"exports/**"`), and keep the built-in globs you still want |
| `egress.allow` | `[]` | Hosts the [Bash guard](autonomy.md#bash-guard-guard-bashsh) lets an agent send a local file to (`curl -T`, `-d @file`, `-F f=@file`, `wget --post-file`), for instance your own artifact server; anything else is denied. Host names only, compared without case |
| `github.protection` | written by setup | `ruleset` when the `senior-mode` ruleset protects the default branch; `local` when GitHub refused it (private repository on a Free plan): the branch is not protected on the server, so `run` and `serve` themselves require the three `senior-mode/*` statuses on the head (whatever `github.requiredChecks` says) and a branch up to date with the base before they merge, and an [audit workflow](autonomy.md#audit-of-direct-pushes) reports a push outside a pull request; `none` (write it yourself to opt out) merges nothing on its own ([ADR 0032](../adr/0032-local-protection-on-github-free.md)) |
| `github.requiredChecks` | `true` | `false` keeps `setup github` from adding required status checks: the `senior-mode` ruleset then has no `required_status_checks` rule (one it already had is removed, a check added by hand included), and setup says so. `run` and `serve` then wait for no `senior-mode/*` status before merging (the other bounds hold: protection, `needs-human`, protected zones, external pull requests). For a repository that delivers as [ADR 0016](../adr/0016-this-repository-delivery.md) describes, with `senior-mode check` green as the only gate. Only `true` or `false` |
| `review.sections` | none | Project review checklists, see [below](#project-review-sections) |
| `review.crossModel` | `true` | Whether the reviewer session of [`serve`](autonomy.md#session-roles) runs on another model than the one that implemented the ticket: Opus, or `review.otherModel` when the ticket ended on Opus (an [escalation](autonomy.md) still applies on top). The model is written at the start of the description of `senior-mode/review`. `false` keeps the reviewer on Opus whatever the implementer used. Only `true` or `false` |
| `review.otherModel` | `sonnet` | The model the reviewer runs on when `review.crossModel` is on and the implementer ended on Opus (an alias such as `sonnet`) |
| `project` | written by setup | Board owner, number, id, and field and option ids, so no agent looks them up again; the text field `Paths` has an id and no options |
| `board.template` | the senior-mode template Project | Id of the Project that `setup github` copies (`copyProjectV2`, without draft issues) when the repository has none, and that `setup github --migrate` builds the new board from. Set the id of your own template, for instance an organization's; the copy brings its views, fields and built-in workflows. A fine-grained token bound to another owner cannot read the default one: setup says what to do, and `--upgrade` then uses a built-in list of its fields |
| `vision.maxLines` | `100` | Lines `docs/vision.md` may have; `check` fails above it (a positive whole number). See [`docs/vision.md`](commands.md#frame) |
| `docs.extra` | none | Extra living documents the `docs` skill keeps current after a merge: a list of `{ "path", "purpose" }`; its changes are flagged for human review. Add it yourself |
| `context.claudeMdLines` | `80` | Most lines a tracked `CLAUDE.md` may have before `check` fails (context hygiene); a whole number from 1 |
| `wip` | `1` | Open tickets In progress at once: `senior-mode start` refuses another and names the one to finish first; `status` shows the count when it is over. A [run](autonomy.md#run) is bounded by `autonomy.parallel` instead, and is the only caller that skips `wip`: it proves itself with a token, so setting `SENIOR_MODE_RUN=1` by hand does not |
| `hygiene.days` | `14` | Age in days (a positive whole number). [`senior-mode clean`](autonomy.md#hygiene) removes the remote branch of a merged or closed pull request and the run files under `.git/senior-mode` older than that (`--days` overrides it). The hygiene report of `senior-mode status` and `retro` ([commands](commands.md)) calls an open pull request with no activity for that long stale (reported, never acted on), and `status --fix` only deletes a branch whose last commit, or moves a ticket whose last activity, is older |
| `autonomy.maxTickets` | `3` | Tickets per [run](autonomy.md#run) |
| `autonomy.parallel` | `1` | Tickets a run works on at once, and the number of [session slots](autonomy.md#session-slots); those whose [Paths](autonomy.md#run) overlap never run together, and one with no Paths runs alone |
| `limits.prLines` | `400` | A positive whole number of lines. `senior-mode pick` batches Ready S tickets whose Paths overlap, at most `prLines` / 50 per batch (3 at most; an S is about 50 lines), see [batches](autonomy.md#run) |
| `limits.diffLines` | `{ "S": 300, "M": 800, "L": 2000 }` | Positive whole numbers of changed lines by Size: the budget of a pull request for the ticket it closes (a batch sums its tickets' budgets). Lockfiles, generated files and fixtures are not counted. `ready --pr`, `run` and `serve` treat a pull request over budget as [not ready](autonomy.md#ready-pull-request); a key you set replaces its default, the others stay |
| `autonomy.maxConsecutiveFailures` | `2` | Failed tickets in a row after which a run starts no new one |
| `autonomy.merge` | `false` | Whether a run merges the pull requests that pass every bound. Under [`serve`](commands.md#the-senior-mode-script) it defaults to `true` unless the repository sets it ([ADR 0018](../adr/0018-daemon-merge-policy.md)); the setup question "may agents work alone" writes it (`setup answers --autonomy`) |
| `autonomy.escalate` | `true` | Whether a ticket that fails on Sonnet is retried once on Opus |
| `autonomy.sessionTimeout` | `90` | Minutes a ticket session may run (a whole number from 1 to 1440). Past it, a [run](autonomy.md#run) kills the session (its process group), labels the ticket `needs-human` with the log path, counts a failure for the circuit breaker and does not retry on Opus; the ticket's Status is left as it is. The docs session after merges is bounded by the same limit |
| `autonomy.schedule` | `"02:00"` | Time of day (`HH:MM`) of the [scheduled run](autonomy.md#scheduled-runs), unless `senior-mode schedule install --at` says otherwise |
| `autonomy.ticketsPerHour` | `6` | Tickets [`serve`](commands.md#the-senior-mode-script) begins in any 60 minutes (a whole number of at least 1). It counts ticket starts, not the role sessions a ticket costs (test author, implementer, retries, reviewer, integrator); a resume after a transient error is no start. Past it a new ticket waits for the next poll and the log names this cap |
| `autonomy.sessionsPerHour` | `0` | Safety cap on all the sessions `serve` launches in any 60 minutes, roles and Opus retries included; `0` means 6 per slot (6 × `autonomy.parallel`). Past it any launch waits for the next poll and the log names this cap |
| `autonomy.userSettings` | `false` | Whether `run` and `serve` sessions load the owner's user-level Claude Code configuration (user `CLAUDE.md`, plugins, MCP servers, settings). Off, a session sees only the project's settings and MCP servers and the plugin, the same on every machine ([autonomy](autonomy.md#sessions-without-a-human)) |
| `autonomy.minMemoryMB` | `1024` | Available memory (MB, `MemAvailable`) under which `serve` launches nothing until the next poll; `0` turns the check off. `serve` also waits while the load average is over the CPU count |
| `serve.interval` | `60` | Seconds between two polls of `serve` (a whole number of at least 1) |
| `serve.grace` | `600` | Seconds `serve` lets running sessions finish after `TERM` before it kills them and labels their tickets `needs-human` (`0`: at once). The unit written by `serve --install` waits this long plus a minute |
| `serve.breakerCooldown` | `300` | Seconds `serve` stays paused after `autonomy.maxConsecutiveFailures` ticket failures in a row, doubled at each pause that no delivery separates from the last (a day at most); `senior-mode serve --resume` ends it sooner |
| `notify.mention` | `""` | Who the comment of an [alert](autonomy.md#alerts) mentions (a login, with or without `@`); the repository owner when empty |
| `notify.webhook` | `""` | URL that gets a JSON `POST` `{event, repo, number, url, reason}` for each alert (`needs-human`, `failed`, or `breaker` for the circuit breaker's pause); off when empty. The environment variable `SENIOR_MODE_NOTIFY_WEBHOOK`, when not empty, wins over it: a URL that is its own secret (an ntfy.sh topic, a Slack incoming webhook) then stays out of the tracked config, for instance in an `Environment=` or `EnvironmentFile=` line of the `serve` unit |
| `notify.digest` | `true` | Whether `serve` posts `status --since 24h` as a Project status update once a day |
| `agent.command` | `claude` | The headless CLI `run` starts for each ticket and for the docs session, on `PATH` or in `~/.local/bin`; the guards of senior-mode do not hold under another CLI until it supports them (see [Run](autonomy.md#run)) |
| `e2e.slots` | `2` | End-to-end suites that may run at once on the machine (the check named `e2e`) |
| `slot` | `""` | A shell command that derives the environment of a [session slot](autonomy.md#session-slots) from `SENIOR_MODE_SLOT`: it prints `KEY=VALUE` lines (a `PORT`, a `DATABASE_URL`, a cache directory) that are exported into the session. Empty: the session only gets `SENIOR_MODE_SLOT`. Names starting with `SENIOR_MODE_` are refused |

`senior-mode config get <key>` prints a value, with dots for nested keys (`ci.mode`). The optional keys
(`protected`, `secrets`, `envGuard.forbidden`, `review.sections`, `docs.extra`, `github.protection`, `slot`)
print `[]` (an empty line for `github.protection` and `slot`) when absent (`github.requiredChecks` prints `true`); a key the plugin does not know is an error.

## Validation and the JSON schema

The file has a JSON schema, `plugins/senior-mode/schema/senior-mode.schema.json`. `setup repo` writes
its URL as `$schema` in `.claude/senior-mode.json` (an existing `$schema` is kept), so an editor
completes the keys and flags a typo as you write it.

`senior-mode config validate` reads the file against the same schema, with no other dependency than `jq`,
and `check` runs it as its `config` step:

```
error: autonomy.maxTicket: unknown key, did you mean maxTickets
error: ci.mode: "actoins" is not one of "local", "actions", "existing", did you mean "actions"
error: autonomy.sessionTimeout: 0 is below the minimum 1
warning: preset: "typescript" is deprecated, use "node"
```

- An **unknown key** is an error, with the closest known key when there is one: a typo no longer
  falls silently back to a default.
- A value **out of its domain** (a type, a list of values, a bound, a pattern) is an error that says
  what is allowed.
- A **deprecated** key or value is a warning, with its replacement; `check` prints it under the `ok`
  of the step.

A key that the plugin reads but the schema lacks is a bug of the plugin: a test keeps every key of the
defaults in the schema.

## Layers, overrides and process profiles

Customization follows the [levers that add and never lift](../adr/0027-customization-levers-that-add-and-never-lift.md)
([spec](../specs/330-customization-levers.md)).

### Layers

A key takes the value of the highest of five layers; objects merge key by key, a list or a scalar of a
higher layer replaces the lower one. Lowest first:

1. the plugin defaults;
2. the **profile** (`process.profile`, below);
3. the **organization**: `<git common dir>/senior-mode/organization.json` (shared by the worktrees of a clone;
   `.github` repository of the organization, copied there by whoever manages the machine);
4. the **repository**: `.claude/senior-mode.json`;
5. the **local** file, untracked: `.claude/senior-mode.local.json` at the root of the main worktree.

The safety lists (`protected`, `secrets`, `envGuard.forbidden`) are the **union** of the layers: a layer adds to
them, none removes. `senior-mode config explain <key>` prints the value, the layer that won, and every layer's
value with the ones it shadows:

```
wip = 7
winner: local (.claude/senior-mode.local.json)
layers, highest first:
  local         7  wins
  repository    4  shadowed by local
  defaults      1  shadowed by local
```

`senior-mode serve` and `run` read the configuration, the profile files, the lifts' ADRs and the overrides from
the **base branch** (`origin/HEAD`), never from a pull request's head or the working tree
(`SENIOR_MODE_CONFIG_SOURCE=base` does the same by hand). The result is checked first: an invalid one (an unknown
key, an unknown profile, a lift without its ADR) leaves the **last valid** config in force, says so once on
stderr, and says when a valid one returns. The last valid one is kept in `<git common dir>/senior-mode/`.

### Overrides

A file under `.claude/senior-mode/overrides/` with the path of a plugin file **replaces** it, and
`NAME.append.EXT` **adds** to it: `overrides/skills/review/SKILL.append.md` extends the review skill,
`overrides/agents/reviewer.md` replaces the reviewer agent. Only `skills/`, `agents/` and `templates/` can be
overridden: the hooks and the CLI are the safety base. `senior-mode override list` lists them, `override show
skills/review/SKILL.md` prints the text in force, and `context` tells a session which overrides bind it.
`setup repo` writes a template with its override applied. `config validate` refuses a file that targets nothing
(with the closest plugin file) or a hook.

### Process profiles

`senior-mode setup answers --strictness strict|fast` chooses the profile of the repository layer: `strict` writes no
key, `fast` writes `process.profile` and the lift with its ADR (below).

A profile is a file: `plugins/senior-mode/profiles/<name>.json` (shipped), or
`.claude/senior-mode/profiles/<name>.json` in the project (shadows a shipped one of the same name). It has
`description`, `extends` (the profile it derives from), `config` (a layer of `.claude/senior-mode.json` keys) and
`gates` ([schema](../../plugins/senior-mode/schema/profile.schema.json)). `process.profile` chooses it:

```json
{ "process": { "profile": "team" } }
```

- `strict` (the default): every locked gate stands.
- `fast` ([ADR 0016](../adr/0016-this-repository-delivery.md)): no independent review, a pull request merges
  once `check` is green.
- A custom profile: `{"extends": "strict", "config": {"wip": 2}}`.

The **locked safety base** is the secret scan, the protected zones, the bash guard, no force-push or
`--no-verify`, `check` green before a merge, and the trust gate; `process.gates` says which stand. Lifting one
means a profile that sets it to `false` **and** an entry in `process.lifts` of the repository layer naming an ADR of
the repository whose status is `accepted` and which is on the base branch:

```json
{ "process": { "profile": "fast", "lifts": [{ "rule": "review", "adr": "docs/adr/0016-this-repository-delivery.md" }] } }
```

Without the ADR the lift is refused with the reason (`config validate` fails, the gate stays locked, the daemon
keeps the last valid config). A lift in another layer is ignored. In this version only the review gate can be
lifted: a profile that opens another gate is refused. `status` shows the profile and one `WARNING locked gate
lifted` line per lift.

### Diagnosing the configuration

`senior-mode doctor` reads the configuration like `config validate` does and adds the rest of the installation
(tools, logins, hooks, board, ruleset). Each finding names its layer and the command that fixes it. Its
"Customization" section answers "what did we change?": the profile, the lifted gates with their ADR, the overrides and
the values each layer sets. See [`senior-mode doctor`](commands.md).

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
- `senior-mode check` prints `ok`, `skip` or `FAIL` per check with the time it took, with the last 20 lines of a failure (the dependency audit shows every blocking advisory, up to 100).
  The full output of a failed check is kept in `senior-mode/check-logs/<time>-<pid>-<check>.log` of the git
  directory (the 20 latest are kept) and its path is printed as `full log: <path>` under those lines.
  A check whose first output line is `skipped: <reason>` passes and prints `skip <name>: <reason>`,
  so a check that had nothing to do is visible instead of a silent `ok`.
- On a push the `pre-push` hook gives the checks the paths the push changes, in a file named by
  `SENIOR_MODE_CHANGED_FILES` (unset when they cannot be worked out: a deletion, a new branch with no
  base). A check that can narrow itself to them does; the others ignore it. A narrowed run is not
  recorded for `publish`: `senior-mode check` without `--pre-push`, `publish` and CI run every check in full.
  This repository's `script tests` check (`.github/scripts/script-tests.sh`) runs its test files in
  parallel, one per CPU, and on a push only those the changed paths touch: a changed test, or a test that
  names the changed file; a path no test names (or `bin/senior-mode`) runs them all.
- Two `check` runs at once (parallel sessions in two worktrees) share no temp path: each run gives its checks
  a `TMPDIR` of its own, removed when it ends (the `e2e` suite gets one too, its machine-wide slot lock
  does not), and the `script tests` check gives its test files a temp directory and an `XDG_RUNTIME_DIR`
  of their own. A check that needs a port or a fixed name derives it from `TMPDIR`, or from
  `SENIOR_MODE_E2E_SLOT` for the `e2e` check, never from a constant.
- A node project that declares dependencies but has no `node_modules` fails at once with
  `dependencies not installed: run <install command>`, before any check runs.
- When `envGuard.forbidden` lists something, setup adds the `env guard` check (below).
- `check` starts with three built-in steps that are not in the list: the `secret scan`, which cannot be
  turned off, the `dependency audit`, which `audit: false` turns off, and the `new dependencies`
  lookup (all below). A passing check
  that has warnings prints them under its `ok`.

Not in the list yet: spec drift (planned, no milestone yet). You can add your own as a check entry.

### Secret scan

`senior-mode check` reads the lines your branch adds (`git diff <base>...HEAD`, the base being the
default branch) and fails on a provider key (AWS, GitHub, GitLab, npm, Stripe, Slack, Google, OpenAI,
Anthropic, SendGrid, Azure storage), a JWT, a URL with credentials (`scheme://user:password@host`, the
user may be empty: `redis://:password@host`), a private key, or a value of 16 characters or more
assigned to a name such as `password`, `secret`, `token` or `api_key`. That last kind is a heuristic,
not an entropy measure: the value needs a letter and a digit, and placeholders, brackets and dotted
identifiers (`process.env.TOKEN_1`) are left alone. In a URL, the password is skipped only when
it is, as a whole, one template (`${X}`, `$(X)`, `$X`, `{X}`, `{{X}}`, `%(x)s`, `%s`, `<x>`, `***`, with `X` an
identifier) or, as a whole, a word such as `password`, `changeme`, `your_password` or `test`; a short password,
one with digits (`Secret123`) or one that merely contains a template or `test` (`Zq9{x}`) is reported. Known
trade-off: a real password that is only `$name` or `{name}` is taken for a template and not reported. The scan prints `file:line: kind` and never the value. The patterns
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

### New dependencies

Agents invent package names, or mistype popular ones, and an attacker can publish under that name
(slopsquatting). The `new dependencies` step looks up every dependency the branch adds, against where it
left the default branch, to a `package.json`, `requirements*.txt`, `pyproject.toml` (PEP 621 and
Poetry), `Cargo.toml` or `go.mod`, on its registry (npm, PyPI, crates.io, the Go module proxy). Local,
git, URL and indirect Go dependencies are left out. The step fails when a package:

- is not on its registry;
- was first published less than `security.minPackageAgeDays` days ago (default 30);
- had fewer than `security.minWeeklyDownloads` downloads last week (default 50; crates.io gives 90
  days, divided by 13; the Go proxy gives none, so Go modules are not held to it).

A name one or two letters from a popular package of `popular-packages` (in the plugin) is a warning.
A registry that does not answer leaves its packages unchecked and says so: the step is a `skip` when
none answered, and a warning names the unchecked packages otherwise. Both thresholds are whole numbers
from 1. `SENIOR_MODE_REGISTRY_TIMEOUT` bounds each request (15 seconds).

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
| `existing` | Reuses the project's CI ([ADR 0022](../adr/0022-adapt-to-the-existing-project.md)): no workflow is disabled and no `senior-mode.yml` is written; the ruleset requires the project's own contexts (`workflow.ci.required`) next to `senior-mode/ci`, `senior-mode/review` and `senior-mode/security`. A check that a job of `ci.jobs` covers is not run again by `check --ci-only` or by `publish`: the state of that job on the commit is read instead (`success` passes, a running or missing job is `wait`, a failure fails with the URL of its run). `setup repo` proposes it when workflows ran on pull requests in the last 30 days; the pre-push hook still runs the covered commands so a push fails fast. |
| `actions` | Adds `.github/workflows/senior-mode.yml`: on pull requests and pushes to the default branch, it installs dependencies (with caching), runs the checks, sets `senior-mode/ci`, runs a dependency review, and releases (below). Re-enables it if `local` disabled it before. |

Switch with `senior-mode setup github --ci actions` (or `local`, or `existing`), then `senior-mode setup repo`.
Your other workflows stay as they are in `actions` mode; turn one back on with `gh workflow enable <name>`.

When `github.protection` is `local` (private repository on GitHub Free), setup keeps or forces `ci.mode` `local`:
the pre-push hook is the only gate on a push, because nothing makes GitHub wait for the statuses. `run` and `serve`
still merge, with senior-mode as the gate (see `github.protection` above); anyone with push access can still push to
the default branch, and the audit workflow only reports it. Upgrade or go public, then run `senior-mode setup github`
again to get the ruleset and `"ruleset"`; `ci.mode` stays `local` until you pass `--ci actions`.

`setup github` also turns on Dependabot alerts, secret scanning and push protection where the plan
allows it. It turns on no Dependabot security updates and writes no `.github/dependabot.yml`; see [GitHub's scanners](autonomy.md#githubs-scanners).

### Following the project's workflow

`senior-mode setup repo` reads the repository and GitHub (never changes them) and records what differs from
senior-mode's defaults under `workflow`; `--dry-run` prints the findings with their evidence and writes
nothing, `--adopt` opens them as one pull request, `docs: adopt senior-mode`. A question it cannot ask
takes the recommended answer, printed as `ask: ... (assumed)`. A key you already set is kept. Without a
`workflow` key nothing below applies.

| Key | Used for |
|---|---|
| `workflow.model`, `base`, `integration` | `trunk`, `integration` or `gitflow`; `base` is the production branch, `integration` the branch tickets start from and their pull requests target (`start`, `run`, `serve`, `ready`, `check`, the hooks) |
| `workflow.release.branches`, `release.hotfix` | Release lines a ticket may target with a `Base: release/1.4` line (else it is `needs-human`), and the prefix of a `hotfix` ticket's branch, cut from `base` |
| `workflow.branch.pattern`, `branch.types` | Branch name with `{type}`, `{issue}`, `{key}`, `{slug}` (default `{type}/{issue}-{slug}`) and the project's names for `feat`, `fix`, `chore`; the pattern also maps a branch back to its ticket for `status` and `clean` |
| `workflow.commit.format`, `pattern`, `scopes` | `conventional`, `ticket-prefix` or `free`; the regex the `commit subjects` check and the `commit-msg` hook enforce (`free`: any subject, and no release-please configuration) |
| `workflow.pr.template`, `title`, `link` | Template whose headings a pull request keeps, title style, and the keyword that links the issue; `ready` refuses a pull request that differs |
| `workflow.merge` | `rebase`, `squash` or `merge`: `run`, `serve` and the merge helper use it, and `setup github` allows it in the ruleset without `required_linear_history` and keeps the repository's other methods |
| `workflow.labels` | The project's own label that stands for a senior-mode one (`"type:bug": "bug"`); `setup github` does not create the mapped ones |
| `workflow.tracker` | `{ "kind", "key" }` of an external tracker; a ticket carries its key in a `Tracker: ABC-123` line, and a pattern that needs the key labels a ticket without one `needs-info` |

The ruleset still covers the default branch only: a project that works on `dev` is not protected there by
`setup github`.

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
