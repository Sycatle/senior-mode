---
id: 471
title: senior-mode enforces code rules on what a pull request adds, by tool first and by review for the rest
status: accepted
size: L
paths: ["plugins/senior-mode/bin/**", "plugins/senior-mode/rules/**", "plugins/senior-mode/presets/**", "plugins/senior-mode/skills/review/**", "plugins/senior-mode/skills/setup/**", "plugins/senior-mode/agents/**", "plugins/senior-mode/templates/**", "docs/guide/**"]
adrs: ["0022", "0027", "0028", "0029"]
issue: "#471"
---

# senior-mode enforces code rules on what a pull request adds, by tool first and by review for the rest

## Problem

Today the code rules of a project managed by senior-mode are sentences: "no duplication", "errors
handled at boundaries", "no disabled lint rules" (`skills/review/SKILL.md`, `skills/verify/SKILL.md`,
`templates/en/principles.md`). Only the model's judgement applies them, and nothing catches a
`// eslint-disable`, a `catch {}`, a `fetch` with no timeout, a helper rewritten next to the one that
exists, or a function of 200 lines. With 100%-AI development on long-lived projects, every rule left to
judgement drifts. The owner decisions of 2026-11-23 (issue #471) are fixed; this spec makes them
testable.

Goals: what a tool can detect fails `senior-mode check` (§2 to §5); what it cannot is an explicit review
checklist (§7); agents know the shared code before they write (§6); the bar applies to what the pull
request adds, and existing code only never gets worse (ADR 0022, spec 409 §5).

Non-goals: fixing existing debt (spec 409 §7); performance rules (epic #472); how fast the checks run,
the tiers and the warning period of a new rule (epic #474, ADR 0028).

Reused, not redone: #420 (lint and coverage ratchet, `ratchet.patchCoverage`, `.claude/ratchet-baseline.json`),
#337 (architecture rules `forbidImport`, `maxLines`, `banned`, with their baseline), #391 (journey E2E
tests), #474 (tiers, per-rule timing and cache, compact output, warning period).

**Blocked by #474.** Every rule below declares a tier and starts as a warning; both mechanisms come from
spec 474 and ADR 0028. No slice that adds a blocking rule merges before them (Delivery).

## Acceptance criteria

Criteria sit in their section (§2 to §8). Every rule has an id, a tier and a fix line, and the bar is
the one in spec 409 §5: a new file meets it whole; in a modified file, no finding is allowed on an added
or changed line; untouched code is never measured.

## Out of scope

- Rewriting a project's existing linter configuration without the owner's yes (ADR 0022).
- EXPLAIN plans, N+1, bundle budgets, benchmarks (epic #472).
- Languages with no preset: the generic preset gets the built-in detections (§3) and duplication only.

## Test seams

- `bin/lib/rules.sh` (new): the engine and the built-in detections, through
  `bin/tests/test-rules.sh` with `git` fixture repositories whose diffs add each pattern in each
  language, and a `gh` stub for issue existence.
- `check` through `bin/tests/test-check.sh` (rule lines, tiers, exit code).
- Rule packs: fixture projects per preset in `bin/tests/fixtures/rules/<preset>/`, with the tools
  stubbed by scripts that print their machine output, so tests never need the real tools.
- `setup repo` through `bin/tests/test-setup.sh` (proposed packs, adoption report, `dependabot.yml`).
- Review sections, scout map and implementer behaviour through `evals/` with `claude -p` on the sandbox
  before merge (ADR 0011).

## Users and journeys

- **The implementer** writes a ticket: its prompt carries the rules of its languages and Paths and the
  shared-code map (with #474); `check` names each finding as `file:line rule-id: message (fix: ...)`.
- **The reviewer** reads the sections of §7 that the diff calls for and the suppressions the diff adds.
- **The owner of an existing project** sees in the adoption pull request (spec 409 §4) which rules its
  tools already cover, which are proposed, and turns a rule off only with a written reason.

## Design

### 1. Rules, packs and configuration

A rule is declared once in the plugin, in `plugins/senior-mode/rules/<pack>.json`:

```json
{ "id": "swallowed-error", "tier": 2, "kind": "pattern", "ext": ["ts", "tsx", "js", "jsx"],
  "pattern": "catch\\s*(\\([^)]*\\))?\\s*\\{\\s*\\}", "fix": "handle, rethrow with context, or log and say why" }
{ "id": "dead-code", "tier": 2, "kind": "tool", "run": "npx knip --reporter json", "format": "knip",
  "fix": "remove it, or use it in this pull request" }
```

- `kind` is `pattern` (built-in, §3) or `tool` (an outside tool whose output an adapter in
  `bin/lib/rules.sh` turns into `file:line rule-id: message` lines). Linter rules (types, complexity,
  a11y lint) are not tool rules: they are findings of the project's lint command, counted by the #420
  ratchet; the pack only proposes their configuration (§4).
- A preset names its packs (`"rules": { "packs": ["node"] }`, `common` always added). `common` holds the
  language-independent rules (TODO without issue, suppression format).
- The project config may only narrow or turn off, with a reason, in `.claude/senior-mode.json` (a
  protected path, so the change goes to a human):

```json
"rules": {
  "off": { "debug-print": { "why": "a CLI prints by design", "paths": ["src/cli/**"] } },
  "shared": ["src/lib/**", "src/components/ui/**"],
  "envModule": ["src/config/**"]
}
```

- `check` runs a built-in `code rules` step after the dependency audit, on the diff against the base
  (`git diff <base>...HEAD`, plus the working tree), with the tier and warning rules of spec 474.

Criteria:

- Given a rule entry without `id`, `tier` or `fix`, or with an unknown `kind`, then `check` fails with a
  configuration error naming the pack and the entry.
- Given `rules.off.<id>` without `why`, then `check` fails with a configuration error; with `why` and
  `paths`, then the rule is skipped only under those paths and `check` prints `off  <id>: <why>`.
- Given a pattern rule that matches a line the diff did not add or change, then `check` passes; given
  the same match on an added line, then it fails with `file:line rule-id: message (fix: ...)`.
- Given a tool rule whose tool is not installed, then `check` fails with `tool missing: <tool>`, the
  install command, and the `rules.off` key that turns it off; it never passes silently.
- Given test files (the preset's test globs), then the detections of §3 marked `prodOnly` do not apply.

### 2. Suppressions

A suppression is any comment or annotation that turns a check off: `eslint-disable*`, `@ts-ignore`,
`@ts-expect-error`, `@ts-nocheck`, `# noqa`, `# type: ignore`, `# pragma: no cover`, `#[allow(...)]`,
`//nolint`, `/* istanbul ignore */`, `c8 ignore`, `.skip`, `.only`, `xit`, `xdescribe`, `@pytest.mark.skip`,
`t.Skip(`, `#[ignore]`, and senior-mode's own `senior-mode: allow <rule-id>`. One added in the diff
must carry an issue reference and a reason on the same line or the line above: `-- #123: reason`.

- Given an added `// eslint-disable-next-line no-explicit-any` with no reference, then `check` fails
  with rule `suppression`.
- Given `// eslint-disable-next-line no-explicit-any -- #123: SDK types are wrong`, and issue #123
  exists, then `check` passes; given #123 does not exist, then it fails `suppression: #123 not found`.
- Given `gh` cannot be reached, then `check` passes the format, prints `suppression: #123 not
  verified`, and the reviewer checks the issue exists and is open.
- Given an added `.only` in a test, then `check` fails whatever the comment says.
- Given `senior-mode: allow debug-print -- #123: progress bar`, then the `debug-print` finding on the
  next line is lifted, and the reviewer lists every lifted finding in the review.

### 3. Built-in detections on the diff (tier 2)

| Rule | Detects on added lines (examples; the packs hold the exact patterns) |
|---|---|
| `swallowed-error` | `catch {}`, `catch (e) {}`, `.catch(() => {})`; `except: pass`, `except Exception: pass`; Go `_ = err`, an empty `if err != nil {}`; Rust `let _ = <call>;` and `.ok();` as a statement |
| `debug-print` (prodOnly) | `console.log/debug`, `debugger`; `print(`, `breakpoint()`, `pdb`; `fmt.Print*`, `println(`; `dbg!`, `println!`, `eprintln!` |
| `todo-without-issue` | `TODO`, `FIXME`, `XXX`, `HACK` not followed by `#<n>` |
| `commented-code` | Two or more consecutive added comment lines that read as code: ending with `;`, `{`, `}` or `)`, or starting with a keyword (`if`, `for`, `return`, `const`, `let`, `def`, `import`, `fn`, `func`); doc comments (`/**`, `///`, `"""`) excluded |
| `outbound-no-timeout` (prodOnly) | `fetch(` with no `signal` or `timeout` in its arguments; `axios.create(` or `axios.<verb>(` with no `timeout`; `requests.<verb>(` with no `timeout=`; `http.Get(`, `http.Post(`, `&http.Client{}` with no `Timeout`; `reqwest::get(`, `Client::new()` |
| `scattered-env` (prodOnly) | `process.env`, `import.meta.env`, `os.environ`, `os.getenv`, `os.Getenv`, `std::env::var` outside `rules.envModule` (preset default: `**/config.*`, `**/config/**`, `**/env.*`, `**/settings.py`) and outside build configs |

- Given a diff adding `} catch (e) {}` in `src/a.ts`, then `check` fails `src/a.ts:<line>
  swallowed-error`.
- Given `console.log` added in `src/a.ts` and in `src/a.test.ts`, then only `src/a.ts` fails.
- Given `// TODO(#42): split` added, then it passes; given `# FIXME later`, then it fails.
- Given three added lines `// const x = 1;` / `// return x;` / `// }`, then `check` fails
  `commented-code`; given a `/** ... */` doc block, then it passes.
- Given `fetch(url)` added, then it fails `outbound-no-timeout`; given `fetch(url, { signal:
  AbortSignal.timeout(5000) })`, or a call through a project client listed in the pack's allowed
  wrappers, then it passes. Same for `requests.get(url)` versus `requests.get(url, timeout=5)`.
- Given `process.env.STRIPE_KEY` added in `src/billing/charge.ts`, then it fails `scattered-env`
  naming `rules.envModule`; given the same in `src/config/env.ts`, then it passes.

### 4. Language rule packs

Each preset proposes a pack: linter configuration for what its linter already does, plus tool rules.
On a new project `setup repo` writes it; on an existing one the adoption pull request (spec 409 §4)
lists for each rule `covered by your config`, `proposed` or `turned off (why)`, and never rewrites the
project's files without a yes (ADR 0022). Starting thresholds, raised later: function cognitive
complexity 15, function length 60 lines, file length 400 lines (a #337 `maxLines` rule), duplicate
block 10 lines or 50 tokens.

| | node | python | go | rust |
|---|---|---|---|---|
| Strict typing (tier 2) | `tsconfig` `strict: true`; `@typescript-eslint/no-explicit-any` | `mypy --strict` or pyright `strict` | compiler | compiler |
| Lint (tier 2, #420 ratchet) | ESLint | ruff (incl. `BLE`, `T20`, `C90`, `PLR`) | `go vet`, staticcheck, golangci-lint (`errcheck`, `gocognit`, `funlen`) | `clippy -D warnings` (`cognitive_complexity`, `too_many_lines`) |
| Format (tier 1 fix, tier 2 check) | Prettier, or the project's | `ruff format` | `gofmt`/`goimports` | `rustfmt` |
| Duplication (tier 2) | jscpd | jscpd | jscpd (or `dupl`) | jscpd |
| Dead code, unused deps (tier 2) | knip | vulture, deptry | staticcheck `U1000`, `go mod tidy -diff` | `dead_code` deny, cargo-udeps |
| Import cycles and layers (tier 2) | dependency-cruiser | import-linter | compiler (cycles), #337 `forbidImport` (layers) | #337 `forbidImport` |
| A11y lint (tier 2, UI only) | eslint-plugin-jsx-a11y, or vuejs-accessibility | — | — | — |
| Mutation (tier 3) | Stryker (incremental) | mutmut | gremlins | cargo-mutants |
| Diff coverage (tier 2, #420) | lcov from the test runner | `coverage xml` | `go test -coverprofile` | `cargo llvm-cov --lcov` |

- **Duplication and the rule of three.** A clone that the diff adds with one existing copy is a
  warning (`duplication: 2nd copy of <file:line>`); with two or more, `check` fails and the fix names
  the `rules.shared` folder to extract into.
- **Layers** are #337 rules; the pack only adds a cycle rule and, when the project declares layers in
  the survey, proposes them as `forbidImport` entries.
- **Mutation** runs on the logic files the diff touches (not tests, not UI or glue as in skill `tdd`),
  in tier 3. Scores per file join `.claude/ratchet-baseline.json` under `mutation`: a touched file's
  score never drops; a new logic file meets `ratchet.mutation` (default 60).
- **Diff coverage** is `ratchet.patchCoverage` of #420 (default 80); this epic only gives each preset a
  coverage command in a format #420 reads.

Criteria:

- Given a new node project, when `setup repo` runs, then `tsconfig.json` has `strict: true`, the ESLint
  config enables the pack's rules, and `.claude/senior-mode.json` names the packs.
- Given an existing project with an ESLint config without `complexity`, when `setup repo` runs, then
  the adoption report lists `complexity: proposed` and the config file is unchanged.
- Given a diff adding a 12-line block identical to one place in the code, then `check` warns; given it
  identical to two places, then it fails `duplication` naming both and the shared folder.
- Given a diff adding an exported function nothing imports, then `check` fails `dead-code`; given an
  unused export that existed before, then it passes.
- Given a diff adding an import that closes a cycle, then `check` fails naming the cycle.
- Given a pull request lowering a touched logic file's mutation score from 70 to 62, then the tier-3
  status fails naming file and both scores; given a new logic file at 55 with `ratchet.mutation` 60,
  then it fails.
- Given each preset's coverage command, when the tests run, then #420 reads the report and applies
  `ratchet.patchCoverage`.

### 5. Accessibility in journey tests

The node preset's journey E2E template (#391) runs axe (`@axe-core/playwright`) on each page the journey
visits. Serious and critical violations fail; existing ones are in the ratchet baseline under `a11y`,
per journey and rule. Axe runs in whatever tier the journey test runs in (spec 328 §5).

- Given a touched journey whose page gains an input without a label, then its E2E test fails with the
  axe rule id, the selector and the page.
- Given a moderate violation, then it is reported and does not fail; given a serious one listed in the
  baseline, then it passes and `--update-baseline` may only remove it.

### 6. Shared code: map, search before creating, rule of three

- The project `CLAUDE.md` template gets a `## Shared code` section: one line per place,
  `path: what lives there` (for example `src/lib/http.ts: fetch with timeout and retries`), inside the
  80-line limit. `rules.shared` holds the same globs.
- The scout drafts the section (it stays read-only: it returns the lines, the agent that edits
  `CLAUDE.md` writes them): at the survey (spec 409 §4), and when asked by `frame` or a retro.
- The implementer prompt carries the map (with #474). Before creating a helper, type or component, the
  implementer searches the map and the code by name and by behaviour; the pull request template gets a
  `New shared code` section: each new export under `rules.shared`, with `searched: <terms>` and what was
  found or reused.
- Principles and the review Design axis say: duplicate once, extract at the third copy into the shared
  place; an interface waits for a second implementation (unchanged).

Criteria:

- Given a diff adding a file under a folder that matches no `rules.shared` glob but matches the
  preset's shared-looking globs (`**/lib/**`, `**/utils/**`, `**/helpers/**`, `**/common/**`,
  `**/components/ui/**`, `internal/**`), then `check` fails `shared-map: add <folder> to ## Shared code
  and rules.shared`.
- Given a diff adding an export under `rules.shared` and a pull request body without `New shared
  code`, then the reviewer marks it blocking.
- Given `setup repo` on an existing project, then the adoption pull request contains the drafted
  `## Shared code` section.

### 7. Review sections

What no tool decides is a checklist. `skills/review/SKILL.md` gains lines on its axes, and two new
sections are read when the diff calls for them:

- **Design axis (always):** reuse of the shared map and rule of three; a new dependency says why a few
  lines of code would not do (also in `dependencies-and-data.md`); comments say why or a constraint,
  never what; names follow the code around.
- **`reliability.md`** (diff touches handlers, routes, jobs, queues, queries, outbound calls, logging):
  errors carry context and a type the caller can act on, and are logged once at the boundary; no secret
  and no personal data in logs or error messages; every entry point (route, handler, webhook, job,
  form) validates its input with a schema (zod, pydantic, serde, the project's); configuration is read
  and validated by a typed schema at boot and fails fast; retries use backoff and only on idempotent
  operations or with an idempotency key; a write across several tables is in one transaction, and a
  concurrent read-then-write is locked or held by a database constraint; minimal observability for a
  service: structured logs with a correlation id per request, a health endpoint, errors sent to the
  project's tracker when it has one.
- **`compatibility.md`** (diff touches a public API, an exported package interface, a schema or
  migration, a config or file format, an event or message): the change works with the previous
  deployed version; a breaking change goes through expand then contract, or behind a feature flag,
  across separate pull requests; a removal is deprecated first; the version or changelog says so.

Criteria:

- Given a diff touching a route handler, then the review applies `reliability.md` and names it under
  sections applied.
- Given a diff that renames a column in one migration, then the review marks it blocking with the
  expand/contract fix.
- Given a diff logging a request body that holds an email, then the review marks it blocking.

### 8. Dependency freshness

`setup github` writes `.github/dependabot.yml` for version updates (security updates stay off, as
today): one grouped weekly pull request per ecosystem for minor and patch, majors ignored. Such a
pull request goes through check and review; it is not from a collaborator, so it merges by a human (ADR
0024, unchanged). Majors become tickets: once a week, `serve` reads the ecosystem's outdated list
(`npm outdated --json`, `uv pip list --outdated`, `go list -u -m -json all`, `cargo outdated`) and
files one `chore(deps): <package> <from> to <to>` ticket per major, reusing an open one of the same
title. A project with its own `dependabot.yml` or Renovate config keeps it (`dependabot.yml: untouched`).

- Given a node project without `dependabot.yml`, when `setup github` runs, then the file has a weekly
  `npm` entry with a `minor-and-patch` group and an ignore on `version-update:semver-major`.
- Given `renovate.json` present, then setup writes nothing and prints `renovate: untouched`.
- Given a major available for `next`, when the weekly pass runs twice, then there is exactly one open
  ticket for it.

## Rollout and risks

- Every blocking rule starts as a warning for the period of spec 474, so its cost and false positives
  show before it blocks anyone.
- Regex detections have false positives: each has a fixture per language, the fix line, and the
  `senior-mode: allow <id> -- #n: reason` way out, which the reviewer lists.
- Proposed linter rules on an existing project raise counts only in files a pull request touches; the
  #420 ratchet keeps untouched files out.
- More tools mean a slower `check`: each rule's tier and the 2-minute budget of spec 474 apply, and the
  retro names the costliest rules.
- `.claude/senior-mode.json` is protected, so turning a rule off always reaches a human.

## Delivery

#487 review sections (§6, §7); #488 engine and suppressions (§1, §2); #489 and #490 detections (§3);
#491 shared-code map (§6); #492 packs for types, lint, format and size (§4); #493 duplication, dead code
and cycles (§4); #494 coverage commands (§4); #495 mutation (§4); #496 axe (§5); #497 dependency
freshness (§8). Order: #487, #488, then #489 to #493, #494 to #496; #497 is independent.

Blocked by #474's slices: #488 by #476 (tiers) and #481 (warning period); #491 by #483 (rules digest and
shared-code map in prompts); #495 by #484 (tier 3). Packs wait for #420 (#492, #494, #495), layers for
#337 (#493), axe for #391 (#496).

## Open questions

- Starting thresholds (complexity 15, 60 and 400 lines, 10-line clones, mutation 60, coverage 80):
  recommended: ship them as pack defaults, raise after the retro shows real numbers.
- Issue existence when offline: recommended: format checked mechanically, existence by the reviewer.
- A Dependabot pull request needs a human merge under ADR 0024: recommended: keep it; revisit trusted
  bots in the customization epic (#330) if the queue grows.
