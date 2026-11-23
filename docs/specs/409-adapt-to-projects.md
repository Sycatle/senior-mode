---
id: 409
title: senior-mode adapts to an existing project instead of imposing itself
status: accepted
size: L
paths: ["plugins/senior-mode/bin/**", "plugins/senior-mode/agents/**", "plugins/senior-mode/skills/setup/**", "plugins/senior-mode/skills/run/**", "plugins/senior-mode/hooks/**", "plugins/senior-mode/templates/**", "docs/guide/**", "docs/knowledge/**", "docs/architecture.md"]
adrs: ["0005", "0006", "0008", "0010", "0020", "0022"]
issue: "#409"
---

# senior-mode adapts to an existing project instead of imposing itself

## 1. Goal and non-goals

Today `setup` assumes a project that starts with senior-mode: trunk, Conventional Commits, rebase
merges, its own ruleset and check list, and in `local` mode the existing workflows disabled. A project
with years of history has a branch model, a commit and PR format, a CI, labels, templates, maybe a
tracker, and code with debt and few tests. Imposing the defaults breaks the team's habits; imposing the
full bar on old code makes every ticket fail. The owner decisions of 2026-11-23 (issue #409) are fixed;
this spec makes them testable. Each criterion is tagged **[v1.0]** (workflow detection and respect:
branches, commits, CI) or **[v1.1]** (survey, ratchet, characterization, debt; ships with the knowledge
epic #325).

Goals: detect the workflow and follow it (§2, §3); survey the architecture and have the owner validate it
in one adoption pull request (§4); hold legacy code to a ratchet (§5 to §7); tell legacy from evergreen (§8).

Non-goals:

- Changing who reviews or merges (ADR 0017, 0018, 0019), or lowering a security rule: the secret scan,
  protected zones and the independent review hold in every project.
- Migrating a project to senior-mode's workflow, or synchronising an external tracker: GitHub issues
  stay senior-mode's work items; what it cannot map is reported (§2.6).
- Fixing the existing debt during adoption: it is measured, frozen, then ticketed (§5, §7).

Reused, not redone: #325 (knowledge notes, briefing, hierarchy), #369 (`setup repo --knowledge`), #337
(architecture rules and baseline), #347 (generated `docs/architecture.md`), #351 (maintenance budget),
#311 and #306 (red tests, mirrored by §6), #352 (verified plan).

## 2. Workflow detection (v1.0)

`senior-mode setup repo` detects the workflow and writes it under `workflow` in
`.claude/senior-mode.json`. Detection reads the repository and GitHub only, prints each finding with its
evidence, and changes nothing but the config and the report. A repository with no `workflow` key behaves
exactly as today, so existing adopters change nothing until they rerun setup.

```json
"workflow": {
  "model": "integration", "base": "main", "integration": "dev",
  "release": { "branches": ["release/*"], "hotfix": "hotfix/*" },
  "branch": { "pattern": "{type}/{issue}-{slug}", "types": { "feat": "feature" } },
  "commit": { "format": "conventional", "pattern": "^(feat|fix)(\\(.+\\))?!?: .+", "scopes": ["api"] },
  "pr": { "template": ".github/pull_request_template.md", "title": "commit", "link": "Closes" },
  "merge": "squash",
  "ci": { "jobs": [{ "context": "ci / lint", "covers": ["lint"] }], "required": ["ci / test"] },
  "labels": { "type:bug": "bug" }, "tracker": { "kind": "jira", "key": "ABC" }, "unmapped": ["merge queue"]
}
```

### 2.1 Branch model

Signals: the default branch (`origin/HEAD`, else `main`, `master`); long-lived remote branches named
`dev`, `develop`, `development` or `staging` with a commit in the last 90 days and not merged into the
default; the base of the last 50 merged pull requests; `release/*`, `hotfix/*`, `support/*` branches and
merged heads. Models: `trunk` (80% or more of merged pull requests target the default branch);
`integration` (80% or more target one long-lived branch `B`: `integration: B`); `gitflow` (`integration`
plus release and hotfix lines in the last 100 branches); `release-branches` (`trunk` plus pull requests
targeting `release/*`). `base` is the production branch, `integration` the branch tickets start from and
merge into; both are the default branch in `trunk`.

- **[v1.0]** Given 45 of 50 merged pull requests targeting a live `dev`, then `model` is `integration`
  and `integration` is `dev`.
- **[v1.0]** Given `dev`, `release/1.4` and a `hotfix/` merge, then `model` is `gitflow` with
  `release.branches` `["release/*"]` and `release.hotfix` `hotfix/*`.

### 2.2 Commit and pull request conventions

Commits: the last 100 non-merge commits of the base; `commitlint.config.*`, `.commitlintrc*` or a
`commitlint` key in `package.json` (extends, types, scopes); `.gitmessage`; a `commit-msg` hook (husky,
lefthook, pre-commit, `core.hooksPath`). `format` is `conventional` (80% or more match
`type(scope)?: subject`, or a commitlint config), `ticket-prefix` (80% or more start with `KEY-123`) or
`free`; `pattern` is the regular expression it checks. Pull requests: the template
(`.github/pull_request_template.md` or `PULL_REQUEST_TEMPLATE/`); the title style of the last 50 merged
(`commit`, `ticket`, `free`); the link keyword in their bodies (`Closes`, `Fixes`, `Resolves`, none); the
merge method (`merge`, `squash`, `rebase`) from the shape of the base's history and the allowed methods.

- **[v1.0]** Given a commitlint config with scopes `api` and `web`, then `commit.format` is
  `conventional` and `commit.scopes` lists them.
- **[v1.0]** Given 90 of 100 subjects shaped `ABC-123 fix login`, then `commit.format` is `ticket-prefix`
  and `commit.pattern` matches that shape.
- **[v1.0]** Given a project hook that owns `commit-msg`, then setup installs none over it and the
  `commit subjects` check runs `commit.pattern`.

### 2.3 CI

Read from `.github/workflows/*` (jobs, triggers, `run` steps), `.gitlab-ci.yml`, `Jenkinsfile`,
`.circleci/`, the required contexts of the base's protection and rulesets, and the check-run names on the
heads of the last 10 merged pull requests. A job `covers` a senior-mode check (`lint`, `typecheck`,
`test`, `build`, `e2e`) when its steps run that check's command or the preset's tool for it.
`ci.required` lists the contexts already required. `ci.mode` is `existing` when a workflow ran on a pull
request in the last 30 days.

- **[v1.0]** Given a job running `pnpm run lint`, the command of the `lint` check, then `ci.jobs` maps
  its context to `lint` and `ci.mode` is `existing`.
- **[v1.0]** Given protection requiring `ci / test`, then `ci.required` lists it.
- **[v1.0]** Given workflows with no run on a pull request for 30 days, then `ci.mode` keeps today's
  default, and the question of §2.7 is asked only if both readings fit.

### 2.4 Labels and issue templates

Repository labels are mapped to senior-mode's by name and by use on the last 100 issues (`bug` to
`type:bug`, `enhancement` or `feature` to `type:feature`, `chore` to `type:chore`, `blocked`,
`security`); `labels` records `senior-mode label: existing label`. A senior-mode label with no
counterpart (`needs-human`, `needs-info`, `gardening`) is created: labels are additive. Issue templates
in `.github/ISSUE_TEMPLATE/` are kept and senior-mode's are not written; `issue create` fills the
matching one and appends an `Acceptance criteria` section when it has none (the Definition of Ready).

- **[v1.0]** Given labels `bug` and `enhancement` and an `ISSUE_TEMPLATE/bug.yml`, then `labels` maps
  `type:bug` and `type:feature` to them, setup creates neither and writes no issue template.

### 2.5 Tracker and board

A GitHub Project linked to the repository is used as today (#176, `--migrate`); its own Status options
are kept and the missing ones reported. An external tracker is detected from keys (`ABC-123`) in
branches, commits and pull requests, and from Jira or Linear links in templates and the README, and
recorded as `tracker: { kind, key }`. An issue carries the key in a `Tracker: ABC-123` line; `{key}` in
the branch pattern or the commit format reads it. An issue with no key where the format needs one gets
`needs-info`.

- **[v1.0]** Given a `Tracker: ABC-123` line and `commit.format` `ticket-prefix`, then the ticket's
  commits and pull request title start with `ABC-123`.

### 2.6 The adoption pull request and what is unmapped

Setup writes the config and a report in one pull request, `docs: adopt senior-mode`, on the detected
integration branch and named by the detected conventions, so the adoption follows them. Its body has
`## Detected` (each key, value and evidence) and `## Not mapped`: one row per practice senior-mode
cannot follow and what it does instead (a merge queue, more than one required reviewer, deploy or
environment branches, a tracker other than GitHub, CI contexts the API does not expose).

- **[v1.0]** Given a `jira` tracker, then `## Not mapped` says issues stay on GitHub and the key travels
  in the `Tracker:` line; given nothing unmapped, the section says `nothing`.
- **[v1.0]** Given `--dry-run`, then setup prints the config and the report and changes nothing.

### 2.7 Questions only when ambiguous

Setup asks in one batch, recommended answer first, only when two readings fit: two bases each above 30%,
an integration branch idle for 90 days, a commit shape between 50% and 80%, workflows present but
unused, a merge method outside the allowed ones. Unattended it takes the recommended answer and lists it
under `## Detected` as `assumed`. It never asks what a signal settles.

- **[v1.0]** Given a clear signal for every key, then setup asks nothing.
- **[v1.0]** Given two bases at 55% and 45%, then it asks one question naming both; unattended it takes
  the one merged last and marks it `assumed`.
- **[v1.0]** Given a rerun, then keys the owner edited are kept and only absent keys are detected.

## 3. Respecting it in run, ready and check (v1.0)

Everything that reads `default_branch`, hardcodes `<type>/<issue>-<slug>`, assumes Conventional Commits
or rebase merges, or disables workflows reads `workflow` first and falls back to today's behaviour for a
missing key.

- **Base.** `start`, `run`, `serve`, `frame` and `ready` branch from and target `integration` (the
  default branch in `trunk`); `check` compares to the same base (secret scan, spec drift, changed
  files). A ticket with a `Base: release/1.4` line (or label `base:release/1.4`) targets that branch if
  it matches `release.branches`, else it is `needs-human`. A ticket labelled `hotfix` branches from
  `base` with the `release.hotfix` prefix; once it merges, `serve` files `chore: back-merge <hotfix>
  into <integration>` when the two differ.
- **Branch name.** `branch.pattern` takes `{type}`, `{issue}`, `{key}`, `{slug}`; `branch.types` maps
  senior-mode's types to the project's. The pattern also parses a branch back to its issue, so `status`,
  `clean` and `start` still find the ticket.
- **Commits.** The ticket prompt carries `commit.format`, `commit.pattern` and the last 3 subjects. The
  `commit subjects` check and the hook validate `commit.pattern`. With `format: free`, setup installs no
  release-please config and no subject check beyond non-empty.
- **Pull requests.** The body starts from `pr.template`, keeps its headings and adds senior-mode's
  blocks (checkpoint, review brief) after them; the title follows `pr.title`, the issue link `pr.link`.
  `ready` refuses a pull request whose base, title or template headings differ, naming each gap.
- **Merge method.** `merge` replaces the `--rebase` of `run`, `serve` and the merge helper; `setup
  github` keeps the repository's allowed methods and drops `required_linear_history` for `merge`.

- **[v1.0]** Given `integration: "dev"`, when a ticket starts, then its worktree branches from
  `origin/dev` and `ready` refuses a pull request based on `main`.
- **[v1.0]** Given `Base: release/1.4` and `release.branches` `["release/*"]`, then the pull request
  targets it; given `Base: prod`, then the ticket is `needs-human`.
- **[v1.0]** Given `branch.pattern` `{key}-{slug}` and `Tracker: ABC-9`, then the branch is
  `ABC-9-<slug>` and `status` maps it to its issue.
- **[v1.0]** Given `pr.template` with a `## Test plan` heading, then the opened pull request keeps it
  and `ready` refuses it empty.
- **[v1.0]** Given `merge: "squash"`, then `run` merges with `--squash` and `setup github` does not
  restrict the repository to rebase.

### 3.1 Reusing the project's CI

With `ci.mode: existing`:

- `setup github` adds `senior-mode/ci`, `senior-mode/review` and `senior-mode/security` to the required
  contexts next to `ci.required`; it removes none, writes no `senior-mode.yml` and disables no workflow.
- A check covered by `ci.jobs` is not copied. `check` runs the checks no job covers (commit subjects,
  secret scan, dependency audit, spec drift, a `test` the CI lacks) and, for covered ones, reads the
  context on the head commit: `success` passes, `pending` or missing is `wait`, a failure fails with
  the job's URL. `senior-mode/ci` is `success` only when both halves pass.
- The pre-push hook still runs covered commands locally so a push fails fast, the only place a covered
  command runs twice; `check --ci-only` skips it.
- `ci.mode: local` and `actions` behave as in ADR 0006.

- **[v1.0]** Given `existing` and a covered `lint` job, then `check` runs no second lint on the CI side
  and `senior-mode/ci` is `success` only when `ci / lint` is `success` on the head.
- **[v1.0]** Given that job still pending, then `check` reports `wait ci / lint` and `publish` sets
  `pending`, not `failure`.
- **[v1.0]** Given existing workflows and `existing`, then setup disables none and adds no workflow
  file; the ruleset keeps `ci.required` and adds the three senior-mode contexts.

## 4. Architecture survey and owner validation (v1.1)

`setup repo --adopt` runs the survey after §2 on a legacy project (§8). The CLI measures (stack,
commands, tree, import graph, churn and fix-commit ratio per path over 12 months, test adjacency, `TODO`
density, coverage report) and prints JSON, so the architect and scout agents interpret facts instead of
exploring. Outputs, in one branch `docs/adopt-senior-mode` (named by §2's pattern) and one pull
request, none binding before the owner merges it:

1. **Architecture map**: prose in `docs/architecture.md` outside #347's generated block: stack,
   commands, layers and modules (one line and paths each), naming and error conventions, patterns.
2. **Knowledge notes** (#325 §2): `docs/knowledge/<slug>.md`, `origin: survey`, `verified` the survey
   day, with the evidence in the body; at most `survey.maxNotes` (default 30).
3. **Retroactive ADRs**: `docs/adr/NNNN-<slug>.md` for decisions the code visibly follows (framework,
   persistence, layering, errors, tests); at most `survey.maxAdrs` (default 10).
4. **Architecture rules**: `architecture.rules` of #337 for layering the code obeys; violations that
   exist go into the baseline (§5); at most `survey.maxRules` (default 15).
5. **Risk zones**: notes titled `Risk: <zone>` with `paths`, the signal (high churn and fixes, no tests,
   no references and no change for 12 months, `TODO` density) and an action, plus a proposal to add
   security-sensitive globs (auth, payments, migrations) to `protected`.

Retroactive ADR: the usual front matter plus `retroactive: true`, `confidence`, `paths` and `evidence`;
sections `Context` (what is observed), `Decision` ("We do X") and `Why` ("because Y"), `Alternatives`
only when evidenced.

`confidence` is `high` (the reason is stated in a commit, pull request, README or comment), `medium`
(consistent in over 80% of the code, no stated reason) or `low` (inferred). A `low` ADR is `status:
proposed` and binds no agent until the owner sets `accepted`. A reason with no evidence is written
`Why: not documented, owner to fill`, never invented. The pull request body lists each file with its
confidence and a checkbox; the owner validates by editing or deleting files, and the merge is the
validation. A rerun never rewrites a file: it opens a new pull request with the additions.

**Project conventions before senior-mode defaults.** The briefing (#325 §3) opens with a `Project
conventions` block: the `workflow` keys, the architecture rules, the accepted ADRs and `convention`
notes whose `paths` overlap the ticket, then `CLAUDE.md` and the project's lint configuration. The
prompts of the implementer, test author and reviewer say: where the project has a convention, follow it
even where it differs from a senior-mode default (naming, layout, error style, test style, libraries).
Nothing here lowers the secret scan, protected zones, independent review, a green `check` or tests for
new behaviour. A convention that contradicts a new spec yields through a new ADR that supersedes it, not
through the code drifting.

- **[v1.1]** Given a legacy project, when `--adopt` runs, then one pull request holds the map, notes,
  ADRs, rules, risk zones and baseline, and nothing outside it changes.
- **[v1.1]** Given a decision with no stated reason, then its ADR is `medium` or `low` and says the reason
  is not documented; given a `low` ADR, then it is `proposed`.
- **[v1.1]** Given a second run, then no existing file is rewritten and new findings come as a separate
  pull request; given 50 candidate notes and `maxNotes` 30, then 30 are written and the rest listed.
- **[v1.1]** Given a `convention` note on `src/api/**` ("handlers return `Result`"), when a ticket
  touches `src/api/x.ts`, then the briefing's first block quotes it and the reviewer flags a diff that
  throws instead.

## 5. Ratchet (v1.1)

Existing debt is measured and frozen; new and touched code meets the bar; the baseline only improves.
Architecture violations follow this in #337 (`.claude/architecture-baseline.json`); this section adds
lint and coverage in `.claude/ratchet-baseline.json` and `senior-mode ratchet`, which shows the three.

```json
{ "version": 1, "createdAt": "2026-11-23",
  "lint": { "total": 412, "files": { "src/a.ts": { "no-explicit-any": 7 } } },
  "coverage": { "total": 41.2, "files": { "src/a.ts": 12.5 } } }
```

- **Metrics.** `lint`: findings per file and rule from the project's own lint command in a machine
  format (`ratchet.lint.command` overrides the preset's: ESLint, ruff, golangci-lint, clippy JSON);
  counts, not line numbers, so unrelated edits do not move them. `coverage`: percent of lines per file
  and total from `ratchet.coverage.report` (lcov or Cobertura).
- **The bar for touched code**, on the diff against the base: (1) a new file has no lint finding and no
  architecture violation and covers at least `ratchet.patchCoverage` (default 80); (2) in a modified
  file no finding sits on a line the diff adds or changes, findings per rule never exceed the baseline's
  and its coverage does not drop; (3) no total rises and no file enters the baseline.
- **Only improves.** `check --update-baseline` lowers an entry when a file got better, deletes it at
  zero and refuses to add or raise one. `check` compares with the baseline on the base branch, so a hand
  edit that raises a number fails. A touched file better than its entry fails with `baseline stale: run
  check --update-baseline`, so an improvement is locked in the pull request that made it.
- **Untouched code** is never measured against the bar. The baseline files are protected paths.
- **Evergreen**: no baseline, the whole code base meets the bar; `ratchet` says `no baseline: full bar`.

- **[v1.1]** Given 7 `no-explicit-any` findings of a file in the baseline, when a pull request changes
  another function and adds none, then `check` passes; given an eighth, then it fails naming file, rule
  and line.
- **[v1.1]** Given a pull request that fixes 3 of the 7, then `check` fails `baseline stale` until
  `--update-baseline` lowers it to 4; given `--update-baseline` on a worse file, then it refuses.
- **[v1.1]** Given a new file with one finding, then `check` fails whatever the baseline says.
- **[v1.1]** Given a hand edit that raises `coverage.total` or adds a file entry, then `check` fails
  against the base branch's baseline.
- **[v1.1]** Given a lint command with no machine format, then `ratchet` reports `lint: not measured`
  with the key to set and `check` does not guess; given an untouched file with findings, no pull
  request fails on it.

## 6. Characterization tests (v1.1)

Before an agent changes existing code that has no tests, it pins what the code does today.

- **Trigger.** At `start` and in the verified plan (#352), `senior-mode untested [--changed]` lists the
  files the Paths and the plan name that are under `characterize.below` percent in the baseline (default
  50), or have no coverage data and no test importing them. Exempt: generated files, types and constants
  with no logic, docs and `characterize.exempt` globs; the plan states each exemption and why.
- **Commit 1 characterizes.** Tests call the existing behaviour and assert what it returns now, odd
  results included, in `test(<scope>): characterize <unit>`, passing on the unmodified code. They pin
  observed behaviour, not intended: where it looks wrong the test pins it and the pull request says so.
- **Commit 2 changes.** A refactor leaves the pinned assertions untouched; a behaviour change edits only
  the assertions the ticket's criteria name, so the diff shows what changed.
- **Review.** The reviewer checks that commit 1 passes on the base (a worktree at that commit) and that
  no pinned assertion changed outside the criteria; a missing commit 1 for a non-exempt file is a
  blocking finding. `ready` runs the same two checks.
- Covering code the ticket does not touch is §7's job.

- **[v1.1]** Given a ticket touching `src/legacy/tax.ts` at 10% coverage, then `untested` lists it and
  the branch's first commit is `test(...): characterize ...` and passes on the base.
- **[v1.1]** Given a refactor whose second commit edits a pinned assertion, then `ready` refuses it.
- **[v1.1]** Given a behaviour change whose criterion says "rounds up", then only the rounding
  assertions change.
- **[v1.1]** Given an exempt file or one at 80% coverage, then no characterization commit is required.

## 7. Debt into maintenance tickets (v1.1)

The debt measured at adoption blocks nothing and is not forgotten: it becomes gardening tickets under
the maintenance budget (#325 §6.1, #351).

- **Sources.** The ratchet baseline, the architecture baseline (#337) and the survey's risk zones.
- **Grouping and ranking.** One ticket per metric and directory at depth 2, ranked by findings (or
  missing coverage) times churn over 12 months, so what changes most comes first.
- **Shape.** Size S, P2, label `gardening`, under the `maintenance` epic, with fingerprint
  `debt:<metric>:<dir>`. Kinds: `lint` (all findings of one rule in one directory), `coverage`
  (characterization tests for one untested, high-churn file, no behaviour change), `architecture` (one
  baselined violation), `dead` (unreferenced and unchanged for 12 months, filed in Backlog, never Ready:
  deleting needs the owner). Each states what it removes from the baseline, in Given/When/Then.
- **Budget.** `setup repo --adopt --debt` files at most `maintenance.maxOpen` tickets (default 5);
  `serve` files the next when a gardening ticket closes. Evergreen projects file none.

- **[v1.1]** Given debt in 8 directories, when `--debt` runs, then 5 tickets are filed, ranked by churn,
  with their fingerprints under the maintenance epic; given an open ticket with the same fingerprint,
  none is filed.
- **[v1.1]** Given a merged gardening ticket that lowers the baseline, then the next ranked one is filed
  on the next `serve` poll, within `maxOpen`.
- **[v1.1]** Given a `dead` zone, then its ticket is in Backlog and `pick` never returns it.

## 8. Evergreen versus legacy detection

`setup repo` records `adopt.kind: "evergreen"` or `"legacy"` and prints the signals. Four signals: (1) at
least 100 non-merge commits; (2) the first commit at least 90 days old; (3) at least 100 tracked source
files; (4) the project's own lint reports findings, or tests are absent or failing. Legacy: two or more
true. Evergreen: none. Exactly one: asked (§2.7), recommended `legacy` when it is signal 4, else
`evergreen`. The owner can set the key by hand.

| | Evergreen | Legacy |
|---|---|---|
| Workflow (§2, §3) | detected, defaults where nothing is found | detected |
| Adoption pull request | config and report | plus survey (§4) |
| Bar | full, on the whole code base | the ratchet (§5) |
| Characterization (§6) | only on untested code touched | on every untested file touched |
| Debt tickets (§7) | none | filed under the budget |

- **[v1.0]** Given 12 commits, 20 files and clean lint, then `adopt.kind` is `evergreen`; given 800
  commits, 3 years and 400 files, then `legacy`.
- **[v1.1]** Given one signal true, then setup asks once, recommended first; unattended it records the
  answer as `assumed`. Given `adopt.kind` set by hand, then setup keeps it.

## Delivery

#413 §2 and §8, #415 §3, #417 §3.1 (v1.0); #419 §4, #420 §5, #422 §6, #424 §7 (v1.1). Order: #413, then
#415 and #417; #419 and #420 after #369 and #337; #422 after #420; #424 after #420 and #351.

## Out of scope

Renaming existing branches or rewriting history; a CI with no commit status or check run per job
(reported as unmapped).

## Test seams

`setup`, `run`, `serve`, `start` and `check`/`publish` (`bin/lib/*.sh`) through the existing
`bin/tests/test-*.sh`, the `gh` stub (merged pull requests, protection, check runs) and `git` fixture
repositories (trunk, `dev`, gitflow, ticket-prefix commits, commitlint, workflows); hooks through
`hooks/tests/`; agent behaviour (survey, characterization, conventions first) through `evals/` with
`claude -p` on the sandbox before merge (ADR 0011).

## Open questions

- The thresholds (80%, 90 days, 100 commits, `patchCoverage` 80) are starting values; recommended: ship
  them as constants and make a key only when a real repository needs another value.
- Merge queue and required-reviewer counts are reported, not mapped; recommended: revisit after the
  first adoption of a repository that uses them.
- A language with no machine-readable lint format is `not measured`; recommended: add formats on demand.
