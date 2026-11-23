---
id: 472
title: Projects get performance rules by default, checked on the diff
status: accepted
size: L
paths: ["plugins/senior-mode/bin/lib/check.sh", "plugins/senior-mode/presets/**", "plugins/senior-mode/templates/**", "plugins/senior-mode/skills/review/**", "plugins/senior-mode/skills/spec/**", "plugins/senior-mode/skills/tdd/**", "plugins/senior-mode/agents/test-author.md", "docs/guide/**"]
adrs: ["0030", "0028", "0029", "0022", "0006"]
issue: "#472"
---

# Projects get performance rules by default, checked on the diff

## Problem

An agent writes code that is correct and slow: a query per item of a list, a table read without a limit,
a foreign key without an index, a migration that locks a table in production, a request handler that
blocks the event loop, a page that ships twice the JavaScript it did last week. None of it fails a test,
and the review only catches what the reviewer happens to look at. Today senior-mode has no performance
rule at all: the `grill` skill asks about performance needs at framing, and that is all.

The owner decided on 2026-11-23 (issue #472) that a project gets a set of performance rules by default,
for its database, its code and its front end, each one checked by a tool where a tool can see it, by
the reviewer otherwise. This spec makes those decisions testable. It builds on three sibling pieces:

- **Tiers (spec 474, ADR 0028).** Every rule declares a tier: 1 runs after each edit, 2 in `check` on
  the diff before the push, 3 in the background from the push, in parallel with the review, and blocks
  only the merge. This epic adds rules; it does not add a tier or a scheduler.
- **Diff detections (spec 471, ADR 0029).** The detection engine of #471 (a rule is a pattern, file
  globs, a tier and a message, applied to added lines, with the suppression syntax `-- #<issue>: <reason>`)
  runs the code detections below. This epic adds rules to it, not a second engine.
- **Ratchet (spec 409 §5, ADR 0022).** Only added and changed code meets the bar; what can be measured
  is compared with the base branch, never with an absolute target the existing code would already miss.

## Acceptance criteria

Each criterion names its tier. A rule whose tool is absent reports `not measured` with the key to set,
and never guesses; a rule never applies to untouched code.

### Database

- **[tier 2] No N+1.** Given the node, python or rust preset with Prisma, SQLAlchemy, Django or sqlx,
  when `senior-mode setup repo` runs, then it offers the preset's query-count helper (§Design) at the
  path in `performance.queries.helper`, and records the key; given an existing helper, it keeps it.
- Given a journey integration test that lists records, when the test author writes it, then it asserts
  the same query count for 1 and for 10 records through the helper; given a list endpoint that issues one
  query per record, then that test fails naming the expected and the actual count.
- Given a diff that adds a list endpoint or a journey with no query-count assertion, when the reviewer
  applies the performance section, then it is a blocking finding.
- **[tier 2] Indexes on foreign keys.** Given a diff that adds a foreign key (a Prisma `@relation` with
  `fields`, or `REFERENCES` / `FOREIGN KEY` in a SQL migration) and no index whose first column is that
  key in the same diff or the schema, when `check` runs, then it fails naming the file, the line and the
  column.
- Given a diff that adds a query filtering (`where`, `WHERE`, `filter`) or sorting (`orderBy`, `ORDER BY`,
  `order_by`) on a column with no index, when the reviewer applies the performance section, then it is a
  blocking finding unless the table is declared small in the spec or the review says why.
- **[tier 2] Bounded reads.** Given an added line in application code (not migrations, seeds or tests)
  with `SELECT *`, or a Prisma `findMany(` with no `take`, when `check` runs, then it fails naming the
  file and line; given the suppression syntax of #471 with an issue and a reason, then it passes.
- Given an added SQLAlchemy `.all()` or Django queryset returned without slicing or a limit in a view or
  handler, then the performance review flags it (no mechanical rule: too many false positives).
- **[tier 2] Safe migrations.** Given a diff that adds or changes a SQL migration under
  `performance.migrations.paths` and the linter in `performance.migrations.linter` (`squawk` for
  Postgres, the preset default), when `check` runs, then it lints those files only and fails on a finding
  (an index created without `CONCURRENTLY`, a column added `NOT NULL` without a default, a column renamed
  or dropped, a type changed, a constraint added without `NOT VALID`), naming file, line and rule.
- Given a Django project, then the linter is `django-migration-linter` on the changed migrations; given a
  database or a migration tool with no linter, then `check` reports `migrations: not measured` and the
  reviewer applies the expand/contract checklist instead.
- Given a rename or a drop that the previous deployed version still reads, when the reviewer applies the
  section, then the change must be split in expand then contract pull requests, or it is blocking.

### Code

- **[tier 2] I/O in a loop.** Given an added line that awaits or calls a database, HTTP or file call
  inside a loop body (`for`, `while`, `forEach`, `map`, list comprehension), when `check` runs the #471
  engine, then it fails naming file and line with the fix "batch it or use a set-based query".
- **[tier 2] Blocking call in a handler.** Given an added synchronous blocking call (`readFileSync`,
  `execSync`, `time.sleep`, `requests.` inside `async def`, `std::thread::sleep` or `std::fs` inside an
  `async fn`) in a file under `performance.handlers` (preset default: routes, handlers, API and server
  folders), when `check` runs, then it fails naming file and line.
- **[review] Performance section.** Given a diff that touches application code, when the reviewer runs,
  then it reads `skills/review/performance.md` and reports, with `file:line`: algorithmic complexity on
  data that grows, repeated work a cache or a precomputation removes, memory held for the life of a
  process, payloads that grow with data, and each database item above.
- **[tier 2] Hot paths have a benchmark.** Given a spec with a `## Hot paths` section naming a path and its
  benchmark, when `check` runs on a diff under that spec's `paths`, then it fails if no benchmark of that
  name exists in the repository.
- **[tier 3] No regression over 10%.** Given a diff under a hot path's `paths`, when tier 3 runs, then it
  runs `performance.bench.command` on the merge base and on the head in the same slot, compares the median
  of each benchmark and fails `senior-mode/perf` when one is slower by more than `performance.bench.threshold`
  percent (default 10), naming the benchmark, both medians and the change.
- Given two runs of the same benchmark that differ by more than the threshold on the same commit, then
  the result is `unstable`: the pull request gets `needs-human` and an issue is filed for that benchmark;
  it is never reported as a pass.

### Front end

- **[tier 2] Bundle budget.** Given a web preset whose build reports JavaScript per route (Next.js build
  output, or `size-limit` with `performance.bundle.command`), when `check` runs the build, then it reads
  the gzip size of each route and compares it with `bundle` in `.claude/ratchet-baseline.json` on the base
  branch.
- Given a route larger than its baseline by more than `performance.bundle.tolerance` (default 5 kB gzip),
  then `check` fails naming the route, both sizes and the largest added module when the build names it;
  given an explicit `performance.bundle.budgets["<route>"]`, then that budget replaces the baseline for the
  route, and raising it is a config change the reviewer sees.
- Given a route smaller than its baseline, then `check` fails `baseline stale: run check --update-baseline`,
  as for lint and coverage (spec 409 §5); given a new route, then its size is recorded on update, never
  rejected.
- **[tier 3] Web Vitals on the preview.** Given a pull request with a preview URL (#389) and routes in
  `performance.lighthouse.routes` (default: the routes of the journeys the diff touches, #391), when tier 3
  runs, then Lighthouse CI measures each route three times on mobile settings and fails
  `senior-mode/perf` when the median breaks a limit: LCP 2500 ms, CLS 0.1, total blocking time 200 ms (the
  lab stand-in for INP), naming route, metric, value and limit.
- Given no preview URL, then the Lighthouse rule reports `not measured: no preview` and does not block.

## Out of scope

- `EXPLAIN` on a seeded database: the owner did not choose it (cost of a realistic seed per project).
- Load testing, production profiling and real-user monitoring (field INP): they need production traffic,
  and agent machines never touch production.
- Fixing existing slow code: untouched code is never measured; a reviewer files what it notices as an
  issue (`senior-mode issue create`).
- A performance rule for a language or ORM not listed here: added on demand, as a preset entry.

## Test seams

- `check` rules (`bin/lib/check.sh`) through `bin/tests/test-check*.sh` with fixture repositories: a
  Prisma schema and SQL migrations with and without indexes, `SELECT *` and `findMany` lines, a loop with a
  query, a handler with `readFileSync`, a stub `squawk` and a stub build output per route.
- Tier 3 (`senior-mode/perf`) through the tier runner of #474 with stub bench and Lighthouse commands that
  print fixed JSON (base and head medians, an unstable pair, a missing preview).
- Query-count helpers through a test per preset fixture (`presets/<p>/` templates run against SQLite or a
  Postgres container where the preset already has one).
- The performance review section and the test-author rule through `evals/` with `claude -p` on the
  sandbox (ADR 0011).

## Users and journeys

- **The owner** adopts senior-mode on a Next.js and Prisma project: `setup repo` adds the query-count
  helper, `squawk` on `prisma/migrations`, the bundle baseline and the bench and Lighthouse keys, and shows
  what it could not measure.
- **An implementer agent** adds a list page: its journey test catches the N+1 on the first run (tier 2),
  `check` names the missing index on the new foreign key, and the bundle rule names the chart library it
  imported on the page.
- **The daemon** pushes; tier 3 runs benchmarks and Lighthouse while the reviewer reads; a 14% slower hot
  path sends the pull request back with the numbers, and the agent has already started its next ticket.

## Design

### Configuration

Presets carry the defaults; `setup repo` proposes them and, on an existing project, validates what is
there without overwriting it (ADR 0022). Every key is optional; a missing tool is `not measured`.

```json
"performance": {
  "queries": { "helper": "test/support/query-count.ts" },
  "migrations": { "linter": "squawk", "paths": ["prisma/migrations/**/*.sql"] },
  "handlers": ["src/app/**/route.ts", "src/server/**"],
  "bench": { "command": "pnpm vitest bench --run --outputJson {out}", "threshold": 10 },
  "bundle": { "command": "next-build", "tolerance": "5kB", "budgets": {} },
  "lighthouse": { "routes": [], "lcp": 2500, "cls": 0.1, "tbt": 200 }
}
```

### Rules and tiers

| Rule | Tier | How |
|---|---|---|
| N+1 | 2 | query-count assertion in journey tests, run by the project's test command |
| Index on foreign key | 2 | schema and migration diff |
| Index on filtered or sorted column | review | performance section |
| `SELECT *`, `findMany` without `take` | 2 | #471 engine |
| Unbounded `.all()` (SQLAlchemy, Django) | review | performance section |
| Safe migrations | 2 | `squawk`, `django-migration-linter`, else review |
| I/O in a loop, blocking call in a handler | 2 | #471 engine |
| Hot path has a benchmark | 2 | spec `## Hot paths` lookup |
| Benchmark regression | 3 | base and head in the same slot |
| Bundle per route | 2 | build output against the ratchet baseline |
| Web Vitals | 3 | Lighthouse CI on the preview |

### Query-count helpers

| Preset | ORM | Helper |
|---|---|---|
| node | Prisma | a client extension counting `$allOperations`, `expectQueries(n, fn)` |
| python | SQLAlchemy | an `before_cursor_execute` event listener as a pytest fixture |
| python | Django | `CaptureQueriesContext` / `assertNumQueries`, wrapped as the same fixture |
| rust | sqlx | a `tracing` subscriber counting `sqlx::query` events |

The test-author agent and the `tdd` skill gain one rule: a journey that lists records asserts a query
count independent of the list size.

### Benchmarks

The spec template gains an optional `## Hot paths` section: a path, the benchmark that measures it, and
why it is hot. Tools per preset: `vitest bench` (node), `pytest-benchmark` (python), `criterion` (rust),
`go test -bench` with `benchstat` (go). Benchmarks run on the base and the head in the same slot and the
same tier-3 job, so no absolute baseline is stored and machine noise cancels out.

### Bundle baseline

`.claude/ratchet-baseline.json` (spec 409 §5) gains a `bundle` key: `{ "<route>": <gzip bytes> }`. It
follows the ratchet rules: compared with the base branch's copy, lowered by `check --update-baseline`,
and a protected path.

## Rollout and risks

- New rules start as warnings for the period set by #474, then block, so a project sees their false
  positives before they cost anything.
- Pattern rules (loops, blocking calls) are heuristics: a false positive is suppressed with an issue and a
  reason (#471), and the retro counts suppressions per rule so a noisy rule is fixed or dropped.
- Benchmarks on a shared agent machine are noisy: the same-slot comparison and the `unstable` result
  keep noise from passing silently or blocking forever.
- Migrations are already protected zones: a migration finding adds to the `needs-human` verdict, it does
  not replace it.

## Delivery

Slices in order: #498 performance review section; #499 query-count helpers; #500 safe migrations and
foreign-key indexes (after #476, the tiers of #474); #501 code detections (after #488, the #471
detection engine, and #476); #502 bundle budget (after #420 and #476); #503 benchmarks (after #484, the
heavy tier 3 of #474, and #476); #504 Lighthouse (after #389, #391 and #484).

## Open questions

- Bundle tolerance of 5 kB gzip per route: recommended as a constant default with the key, revisited
  after the first real project.
- An `unstable` benchmark asks a human; recommended: keep it, and count `unstable` results in the retro
  to decide whether benchmarks need a dedicated quiet slot.
- MySQL and SQLite migrations have no linter in this spec; recommended: review only until a project
  needs one.
