---
id: 325
title: A project stays healthy when agents build it for months
status: accepted
size: L
paths: ["plugins/senior-mode/bin/**", "plugins/senior-mode/agents/**", "plugins/senior-mode/skills/**", "plugins/senior-mode/presets/**", "plugins/senior-mode/templates/**", "docs/guide/**", "docs/knowledge/**", "docs/vision.md", "docs/architecture.md", "evals/**"]
adrs: ["0002", "0017", "0019", "0020"]
issue: "#325"
---

# A project stays healthy when agents build it for months

## 1. Goal and non-goals

A project developed 100% by agents over months must not turn into a mess. Every session gets the
right context for its task (the specs, decisions, history and local pitfalls of the code it will
touch), no more, and the project cleans itself continuously. Sessions are also faster and make fewer
mistakes: they check only what changed, plan before coding, catch their own errors and stop when
stuck. Owner decisions of 2026-11-23 (issue #325 and its "part 2" comment) are fixed; this spec
turns them into testable behaviour.

Problem today: `context()` in `bin/senior-mode` prints a router and, on a ticket branch, the ticket,
its spec and six criteria. What a session learns dies with it or sits in private agent memory
(`memory: project` of `architect` and `reviewer`) that no one reads or checks. After 200 tickets
nothing tells the next agent that a module breaks if imports are reordered, that a rule was tried
and reverted, or that the code drifted from the architecture.

Goals:

- A bounded, ranked, deterministic briefing built from the ticket's Paths (§3), fed by notes that
  live in the repository (§2) and are captured through pull requests (§4).
- Knowledge and architecture that are kept true on purpose (§5, §6).
- Work that always traces back to a goal (§7).
- Faster and smarter sessions (§8).

Non-goals:

- Embeddings, a vector store or any service to run (ADR 0020).
- Replacing `CLAUDE.md` (commands, code map, whole-repository pitfalls; 80 lines, #314) or the
  scout agent, which answers anything deeper than the briefing.
- Plans, progress or journals in files: state stays in GitHub (ADR 0002).
- Changing who reviews or merges (ADR 0017, 0018, 0019).

Related work, reused and not redone here: #304 (cross-model reviewer), #306 (added tests must fail
without the change), #310 (decision log, feeds §3), #311 (criteria become red tests, feeds §8.2),
#313 (size calibration, feeds §8.2 and §8.3), #314 (context hygiene: `check` bounds `CLAUDE.md` and
`SKILL.md` and flags dead paths; §5 extends the dead-path idea to notes), #321 (spike tickets: a
spike's note under `docs/spikes/` may become a `context` note), #308 (decision inbox, v1.3, used by
§8.2). The CLI is split into `bin/lib/*.sh` modules by #315, which this epic waits for: tickets give
Paths as `plugins/senior-mode/bin/**`.

## 2. Knowledge notes

A note is a Markdown file `docs/knowledge/<slug>.md`, `<slug>` kebab-case, one fact per note.

```markdown
---
paths: ["src/billing/**", "src/lib/money.ts"]
verified: 2026-11-23
origin: "#312"
kind: pitfall
---

# Reordering imports in billing breaks currency rounding

`money.ts` patches `Intl.NumberFormat` as a side effect on import; `billing/invoice.ts` must import
it first. Biome's organize-imports moves it; keep the `// biome-ignore` line.
```

- `paths`: non-empty list of globs, same dialect as `protected` and the board's Paths. The note
  is about those files.
- `verified`: date (`YYYY-MM-DD`, not in the future) a person or an agent last confirmed the note is
  true of the code at `paths`.
- `origin`: `#<n>` (ticket or pull request that taught it), `retro`, or a `docs/spikes/` path.
- `kind`: `pitfall` (a trap), `convention` (a rule the code follows), `howto` (a non-obvious
  procedure), `context` (why something is as it is).
- Size: the body (after the front matter) is at most `knowledge.maxLines` lines (default 40). A longer
  subject is split in notes or becomes an ADR or a spec.
- ADRs and specs get an optional `paths` list in their front matter so the briefing can match them.
  An ADR without `paths` is reached only through the `adrs` of a spec.
- Tickets: #333 (format and `check`), #335 (`paths` on ADRs and specs).

Acceptance criteria:

- Given a valid note, when `senior-mode check` runs, then it passes; given a missing key, an unknown
  `kind`, a future `verified`, empty `paths`, a body over `knowledge.maxLines` or a file name that is
  not a slug, then it fails naming the file and the problem.
- Given no `docs/knowledge/`, then `check` reports nothing about notes.
- Given an ADR or spec whose `paths` is not a list of strings, then `check` fails; given an ADR
  without `paths`, then it stays valid.

## 3. The briefing

`senior-mode context` (SessionStart hook) builds the briefing. It never fails and exits 0.

Inputs, all from the repository and GitHub, no embeddings:

1. The ticket's Paths: from the board field Paths, else the spec's `paths`, else none.
2. Specs and ADRs governing the Paths: `accepted` only, `paths` overlapping the ticket's Paths
   (overlap as the collision rule of ADR 0017), plus the ADRs in the `adrs` of the ticket's spec.
3. Knowledge notes whose `paths` overlap.
4. History of the Paths: the last 5 merged commits that touch them with their `(#n)`, date, subject
   and the pull request's key decision (the first line under its `Decision` or `Decisions` heading);
   commits `Revert "..."` in the last 90 days; recurring review findings (review comments end with
   `<!-- finding: <slug> -->`; a slug on 2 or more merged pull requests with overlapping paths and
   covered by no note).
5. Related work: the parent epic, open tickets whose Paths overlap (5 at most), the 3 newest entries
   of `docs/decisions.md` (#310) linked to the ticket or its epic.
6. A bounded repo map (§8.1).

Ranking, deterministic (same input, byte-identical output): within a class, by the length of the
literal prefix of the overlap (longest first), then `kind: pitfall` first, then newest `verified`,
then file name. Classes by priority when the budget is short: the ticket and its criteria, ADRs and
specs, notes, recurring findings and reverts, repo map, history, related tickets.

Token budget: `context.budget`, default 2000 tokens, estimated as bytes / 4. The router and the
ticket with its criteria are never dropped. Candidates are added in rank order until the budget is
full; the last line states what was omitted and that the scout agent has the rest.

Order, from stable to variable, so that the start of the briefing is the same across tickets and the
prompt cache holds: router, vision (goals and non-goals, §6.3), ADRs, specs, notes, repo map, history,
related work, the ticket and its criteria last. `CLAUDE.md` is loaded by Claude Code before the hook
output and is not repeated.

Age: each note is shown as `verified 2026-09-01 (83 days ago)`, and with `stale` when older than
`knowledge.staleMonths` (default 6, §5). Specs and ADRs show their status.

Fallback when GitHub is unreachable: the briefing is built from files and git. The ticket comes from
the branch name and from `.git/senior-mode/ticket/<n>.json`, written at each successful load;
related tickets and review findings are omitted, and one line says so. With no cache, the ticket
line says details are not loaded, as today.

Tickets: #338 (inputs, ranking), #343 (budget, order, age), #349 (history), #354 (related work,
fallback).

Acceptance criteria:

- Given a ticket with Paths `src/auth/**`, a spec and an accepted ADR overlapping them, a note that
  overlaps and one that does not, then the briefing lists the spec, the ADR and only the first note.
- Given candidates over `context.budget`, then the output fits it, keeps the router and the ticket,
  drops the lowest ranked first and says how many items it omitted.
- Given two ticket branches of one repository, then their briefings share an identical start up to
  the first Paths-dependent section.
- Given a note verified 83 days ago, then its line shows the date and `83 days ago`.
- Given `gh` failing, then `context` exits 0 with a briefing from files, git and the ticket cache,
  and a line that names what is missing.
- Given a `superseded` spec or ADR, then it is not listed.

## 4. Capture

Knowledge enters the repository only through pull requests.

- **Implementer**: when a session retried a step twice or more because of a constraint the code does
  not show, its pull request adds (or edits and re-verifies) a note, `origin` its ticket; at most 2
  notes per pull request, none when there is no pitfall. #336.
- **Reviewer**: a finding ends with `<!-- finding: <slug> -->`. When the slug was already on an earlier
  merged pull request with overlapping paths, the reviewer opens a separate pull request
  `docs(knowledge): <slug>` with a `kind: pitfall` note citing both pull requests; if a note already
  covers it, the review cites it instead. #359.
- **Retro**: one pull request per pass, `docs(knowledge): retro <date>`, merging notes with identical
  `paths` and `kind`, deleting notes whose `paths` match no file, and promoting or dropping each
  draft in `.claude/agent-memory/<agent>/`. The agents' private memory is a draft (ADR 0020); their
  instructions say so. #340.

Acceptance criteria:

- Given a session that hit a pitfall, then its pull request contains a valid note; given none, no
  note.
- Given a finding seen on two pull requests, then a `docs(knowledge)` pull request exists and the
  reviewed pull request is untouched.
- Given drafts in agent memory, when `retro` runs, then none older than that pass remains and the
  pull request lists each decision.
- No capture writes to the default branch directly.

## 5. Freshness

A note is true when someone checked it against the code. Rules:

- `verified` changes only in a pull request that re-read the note against its `paths`.
- `check` warns on a note whose `paths` match no file and on a note older than `knowledge.staleMonths`
  (default 6); it fails when the branch deletes or renames a file a note's `paths` match without
  touching that note. #345.
- A note with more than `knowledge.churnCommits` (default 15) commits on its `paths` since `verified`,
  or older than `knowledge.staleMonths`, gets one gardening ticket (`chore(knowledge): re-verify
  <slug>`, size S, label `gardening`, under the maintenance epic), filed by the daily maintenance
  pass of `serve` within the budget of §6.1. The session bumps `verified`, edits or deletes. #357.
- The briefing shows each note's age (§3), so an agent can discount an old note.

Acceptance criteria:

- Given a note citing a glob that matches nothing, then `check` warns and passes.
- Given a branch that renames a file a note cites and leaves the note, then `check` fails.
- Given a note over the churn or age threshold, then `serve` files exactly one gardening ticket for
  it, and none while one is open.

## 6. Anti-entropy

### 6.1 Maintenance budget

`maintenance.share` (default 0.2) is the share of `autonomy.parallel` slots kept for gardening. The
reserved count is `ceil(share × parallel)`. While a Ready ticket labelled `gardening` waits, feature
tickets cannot take the last reserved slot; with none waiting, the slot goes to features. Auto-filed
gardening tickets (stale notes, architecture violations in the baseline, outdated
`docs/architecture.md`, dead paths, spec drift) are size S, priority P2, deduplicated by
fingerprint, capped at `maintenance.maxOpen` (default 5) open, and sit under one standing epic
labelled `maintenance` that `setup` creates. `status` shows the use. #351.

- Given share 0.2 and parallel 4 with Ready gardening and feature tickets, then one gardening session
  runs and features use the 3 other slots.
- Given share 0, then nothing is reserved.
- Given 5 open auto-filed gardening tickets, then a sixth is not filed.

### 6.2 Architecture rules

Rules live in `.claude/senior-mode.json` and are enforced by `check`:

```json
"architecture": { "rules": [
  { "id": "ui-not-db", "forbidImport": { "from": "src/ui/**", "to": "src/db/**" }, "why": "ui goes through services" },
  { "id": "file-size", "maxLines": 500, "paths": ["src/**"] },
  { "id": "no-console", "banned": "console\\.log", "paths": ["src/**"] }
] }
```

`forbidImport` resolves relative and aliased import specifiers (aliases from the preset's config);
`maxLines` and `banned` look at the files matched by `paths`. Existing violations are recorded in
`.claude/architecture-baseline.json` (a ratchet): `check` fails only on violations outside it and
`check --update-baseline` can remove entries, never add. A rule needs `id` and exactly one kind.
#337.

- Given a file under `src/ui` importing `src/db/x`, then `check` fails naming rule, file and line.
- Given the same violation listed in the baseline, then `check` passes; fixed, `check` warns to
  remove it; `--update-baseline` refuses to add one.

### 6.3 Vision

`docs/vision.md` has `## Goals` (entries `G1`, `G2`...), `## Non-goals` and optional `## Constraints`,
at most `vision.maxLines` (default 100). A human owns it (`setup` proposes it for `protected`).
`frame` reads it: an idea contradicting a non-goal is raised as a framing question quoting the
non-goal, and unattended it becomes `needs-human`. The briefing carries its goals and non-goals in
the stable start. #342.

- Given an idea that contradicts a non-goal, then `frame` asks instead of framing it.
- Given a vision file without `## Non-goals`, then `check` fails.

### 6.4 Generated architecture

`senior-mode architecture [--write]` prints, then writes between `<!-- senior-mode:architecture
sha=<hash> -->` markers in `docs/architecture.md`, the directories to depth 2 with their purpose (the
governing spec's title, else the local README's first line), the architecture rules, the ADR index
and the note count. The `docs` skill runs it. When the hash of the current tree, rules and ADRs
differs from the recorded one, `check` warns and `serve` files a gardening ticket. #347.

- Given a changed tree, then `check` warns `architecture.md out of date`; after `--write` it does
  not; text outside the markers is untouched.

## 7. Hierarchy

vision (goals `G1`...) → milestone (its description has `Goal: Gn`) → epic (an issue with
sub-issues and exactly one spec in its body) → ticket (S or M, a sub-issue of an epic).

- `frame` creates milestones that cite a goal chosen with the owner (never invented), epics that link
  one spec, and tickets with `--parent`. #361.
- `status` prints progress per level (closed / total tickets per goal, per milestone, per epic) and
  `status --json` has a `hierarchy` key. A milestone without a goal and an epic without exactly one
  spec are drift. #353.
- Orphan: a ticket with no parent epic, with no exempt label (`hierarchy.exempt`, default `security`
  and `hotfix`) and not under the maintenance epic, or whose epic's milestone has no goal. With
  `hierarchy.enforce: true` the Definition of Ready refuses it (`needs-human`, comment naming the
  missing link) and `pick` never returns it, so the daemon never starts it. `enforce` defaults to
  `false` until the repository is migrated (§9); then `status` only warns. #358.

Acceptance criteria:

- Given enforcement on and a ticket with no parent, then it is not Ready and `pick` skips it.
- Given a gardening ticket under the maintenance epic, then it is accepted.
- Given a milestone with `Goal: G2`, then `status` shows G2's closed/total tickets.
- Given enforcement off, then `pick` is unchanged and `status` lists the orphans.

## 8. Productivity and intelligence

### 8.1 Speed

- **`check --changed`**: each check with a `changed` variant (`checks[].changed` with a `{files}`
  placeholder, or the preset's) runs on the files of the diff against the default branch, committed
  and not; the others run in full and the output says which. The full `check` stays the push gate:
  `--pre-push` and `publish` refuse `--changed`. #339.
- **Repo map**: a section of top-level symbols and signatures of the Paths' files and of what they
  import, at most `context.repoMapTokens` (default 400, inside the budget), from `ctags` or a regex
  fallback per preset language, ranked by how many files reference the symbol, cached by tree sha.
  #362.
- **LSP**: `setup repo` prints the stack's language server and the command that enables it in Claude
  Code and installs nothing; the answer is recorded as `lsp`. #341.
- **Cache-friendly order**: §3.
- **Checkpoints**: `senior-mode checkpoint --done --doing --next --assumption` rewrites the
  `<!-- senior-mode:checkpoint -->` block of the ticket's draft pull request (opened at the first
  push); sessions write it at each commit; a resumed session sees it before the ticket section
  instead of re-exploring. #346.

Acceptance criteria:

- Given a diff, then `check --changed` runs the changed variants on those files only and names the
  checks run in full; `check --pre-push --changed` is refused.
- Given a tree, then the repo map is identical on two runs and a second run reads the cache.
- Given a pull request with a checkpoint, then `context` on its branch prints it.

### 8.2 Reasoning

- **Verified plan** (M and L): before coding, the implementer writes a plan of at most 15 lines into
  the checkpoint; the architect (strong model) checks it against the spec, the ADRs and the
  architecture rules and answers `approve` or `revise`; a second `revise` gives `needs-human`. No code
  before `approve`. S tickets skip it. #352.
- **Self-review**: before `ready`, the session runs the review checklist on its diff and fills a
  "Self-review" table with evidence (a test name or a command and its result) for each acceptance
  criterion; `ready` refuses a pull request with a gap. It adds to, never replaces, the independent
  review (ADR 0019); #311 gives the red tests it cites and #306 makes them count. #356.
- **Stuck detection**: the same normalized error 3 times, no commit or file change for
  `stuck.minutes` (default 20), or tokens above `stuck.tokens` for the ticket's size (calibrated by
  #313) ends the session once and starts one escalated session from the checkpoint; a second trigger
  stops, posts a diagnosis and labels `needs-human`. #360.
- **Ambiguity**: an unattended session facing an irreversible choice it cannot settle from code, spec
  or ADRs posts the question and a recommended option, labels `needs-decision`, checkpoints and stops;
  `serve` starts another ticket and resumes this one on the answer. The decision inbox (#308) lists
  it; until then `needs-human` and the comment are the inbox. Reversible choices keep the recommended
  option. #363.

Acceptance criteria:

- Given an M ticket, then no code is committed before the architect's `approve`.
- Given a pull request whose Self-review table misses a criterion, then `ready` refuses it.
- Given 3 identical errors, then the session is replaced once, and on the next trigger the ticket
  gets `needs-human` with a diagnosis.
- Given an irreversible unattended question, then the ticket is `needs-decision`, the slot is
  released and the answer resumes it.

### 8.3 Learning

- **Failure taxonomy**: `retro` labels each ticket that needed a second review round, an escalation,
  a stuck stop or a revert with one `cause:<x>`: `missing-context`, `fuzzy-criterion`,
  `fragile-test`, `tool` or `weak-model`, quoting the evidence. A cause seen `retro.repeat` times
  (default 3) on the same paths or skill opens one targeted improvement ticket (a note or ADR, a
  stricter Definition of Ready, a test fix, a CLI ticket, a routing proposal). #364.
- **Adaptive routing**: from at least 10 sessions per role and size, `retro` computes the first-pass
  review rate and the cost, and proposes a `models` change as a pull request that a human merges. The
  reviewer never runs on the implementer's model (#304). #365.
- **Best-of-N**: only a ticket that already failed once (a stuck stop, or 2 changes-requested rounds)
  runs in `bestOf.n` (default 2, at most 3) worktrees; the first candidate with green `check` and
  complete self-review that the reviewer prefers wins and the others are closed with a comment. The
  extra sessions count against the hourly ceiling. #367.
- **Skill evals**: a change to a skill or agent that answers a failure cause carries a before/after
  `claude -p` eval of the targeted behaviour on `evals/` fixtures, several runs each, in the pull
  request; `ready` refuses an `improvement` pull request without it. #368.

Acceptance criteria:

- Given 3 tickets with `cause:fuzzy-criterion` on the same paths, then `retro` opens one improvement
  ticket and none when one is open.
- Given fewer than 10 sessions, then no routing change is proposed.
- Given a ticket that never failed, then it runs once; given one that failed, then it runs in
  `bestOf.n` worktrees.
- Given an `improvement` pull request on a skill with no eval table, then `ready` refuses it.

## 9. Migration of existing repositories

Nothing changes for a repository that does nothing: without `docs/knowledge/`, `docs/vision.md`,
`architecture` or `maintenance` keys, the briefing is today's plus specs and ADRs matched by `paths`,
`check` is unchanged, and `hierarchy.enforce` is off. `senior-mode setup repo --knowledge [--dry-run]`
adopts the layout in one pull request `docs(knowledge): adopt long-lived project layout` and is
idempotent:

- adds `paths` to each existing ADR, the union of the `paths` of the specs that cite it (listed in
  the report, to be corrected by hand);
- creates `docs/knowledge/` with a first note per `agent-memory` draft found, and a draft
  `docs/vision.md` from the README for the owner to rewrite (never merged without the owner);
- creates the standing `maintenance` epic and the `gardening` label;
- records the current architecture violations in `.claude/architecture-baseline.json`;
- lists the open tickets that would be orphans and does not change them; the owner attaches them to
  epics, then sets `hierarchy.enforce: true`.

Tickets: #369. Existing tickets #304, #306, #310, #311, #313, #314, #321 are already sub-issues of
#325 and stay as they are; #308 stays in v1.3.

Acceptance criteria:

- Given `--dry-run`, then it prints the files it would write, the orphans and the baseline, and
  changes nothing.
- Given a second run, then it changes nothing.
- Given a repository with no vision file, then `frame`, `check` and `serve` behave as before.

## Out of scope

- Embeddings or any semantic index (ADR 0020); a later spec may add one behind the briefing.
- Cross-repository knowledge (a separate epic on multi-repo products).

## Test seams

`context` (briefing, fallback), `check` (notes, rules, baseline, vision, drift), `status` (hierarchy,
maintenance), `pick` and `ready` (orphans, self-review), `serve` (budget, stuck, best-of-N, gardening)
and `retro` (taxonomy, routing) in `bin/senior-mode` and its `bin/lib/*.sh` modules, through the
existing `bin/tests/test-*.sh` with the `gh` stub and fixture repositories; agent behaviour (notes,
plans, self-review) through `evals/` fixtures with `claude -p`, run on the sandbox before merge
(ADR 0011).

## Open questions

- `hierarchy.exempt` defaults to `security` and `hotfix`; recommended: nothing else is exempt, and a
  bug with no epic goes under the `maintenance` epic.
- Order inside "recurring findings" depends on reviewers writing stable slugs; recommended: ship #359
  with an eval, and let `retro` merge near-duplicate slugs.
- Part 2 of the framing says "v1.0"; the tickets are in milestone "v1.1 Context and intelligence"
  as the owner's brief for this spec asked. Recommended: keep v1.1, since v1.0 is the release gate.
