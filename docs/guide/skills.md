# Skills

Every skill is a step of the delivery lifecycle and a role of the team
([ADR 0009](../adr/0009-lifecycle-and-roles.md)):

| Role | Skills |
|---|---|
| Lead | `triage`, `frame`, `spec`, `adr`, `grill`, `ready`, `brief` |
| Developer | `tdd` (refactoring is a mode of it), `verify`, `commit` |
| Reviewer | `review`, with explain, security, UI and dependencies-and-data sections |
| Release and ops | `run`, `next`, `status`, `docs` |
| Learning | `retro` |

The rules below are the ones Claude loads by itself when the task matches them; the others are
[commands](commands.md). You do not call the rules. Claude loads one when its description matches what
it is doing, and agents start with some of them preloaded (see [Agents](agents.md)). The design is in
[spec §8](../specs/0001-senior-mode.md#8-lifecycle-roles-and-skills).

## `triage`

- **Rule.** Size every request S, M or L before any work, and apply only the ceremony that size
  needs. Any one criterion is enough for the larger size. When unsure, take the larger size.

  | Size | Criteria | Ceremony |
  |---|---|---|
  | S | One module, under ~50 lines, no new dependency, no change to an existing interface, easy to undo | Branch and PR, an issue for a product request; a bug fix still gets a regression test |
  | M | Bounded feature or refactor, under ~400 lines, may add a dependency | Issue, light spec, tests first, PR |
  | L | New subsystem, data migration or model, auth, money, irreversible or cross-cutting change, a changed public interface others depend on, or over ~400 lines | `frame`: ADRs, full spec, epic split into tickets of size M or less; a human accepts first |

- **When.** At the start of every request, and again when a ticket grows during work. A ticket that
  outgrows its size stops, and Claude proposes a split.

## `ready`

- **Rule.** A ticket is Ready only when an agent could deliver it without asking anything: a spec
  merged on the default branch with Given/When/Then criteria (S needs only a clear expected
  behaviour), size S or M, no `needs-info`, every blocker closed, test seams named, and for a slice
  of an L epic, spec and ADRs `accepted`.
- **Outcome.** All pass: status `Ready`. Something missing: `needs-info` label and a comment with a
  recommended answer per question. Only blocked: stays in Backlog.
- **When.** After framing, before a ticket is picked.

## `tdd`

- **Rule.** Tests come from the acceptance criteria. Logic and bug fixes: a failing test first, seen
  failing for the right reason. UI and glue: one end-to-end or integration scenario per criterion.
  Spikes are exempt, but are discarded or tested before merge. Tests go in the same commit as the
  code. A flaky test is a bug: open an issue, never skip it silently.
- **Refactor-only ticket.** Structure changes, behaviour does not. State the goal and the invariant
  first; when coverage is weak, write characterization tests that pin today's behaviour and commit
  them before any change; then small steps, tests after each, one `refactor:` commit per step.
  A test that has to change means behaviour changed: revert. Features and fixes do not ride along.
- **Pitfall.** A step retried twice over a constraint the code does not show becomes a
  [knowledge note](configuration.md#knowledge-notes) in the pull request (at most 2, none otherwise).
- **When.** Before writing or changing production code, for every bug fix, and for "refactor",
  "refacto", "nettoie".

## `commit`

- **Rule.** Atomic Conventional Commits: one logical change, builds and passes on its own,
  `type(scope): subject` in at most 72 characters, a body that says why. No AI co-author trailers.
  Never `--no-verify`, never rewrite a pushed shared branch.
- **When.** Whenever committing, and before pushing.

## `verify`

- **Rule.** "Done" needs fresh evidence. Run `senior-mode check`, read the output (not only the exit
  code), and say exactly what ran. Never weaken a check to get green. A check that cannot run is
  reported as not verified.
- **When.** Before saying a task is done, before pushing, before opening or merging a pull request.
  A hook also enforces it: see [Autonomy](autonomy.md#hooks).

## `brief`

- **Rule.** Every call to the Agent tool carries seven non-empty sections: `## Goal`, `## Context`,
  `## Constraints`, `## Acceptance`, `## Verify`, `## Return`, `## Model`. The hook `brief-guard.sh`
  refuses a call that lacks one (`brief: missing ## Verify (skill brief)`) and logs the others to
  `.git/senior-mode/briefs.jsonl`.
- **When.** Before delegating to a subagent.

## `spec`

- **Rule.** One spec per M or L feature in `docs/specs/<issue>-slug.md` (named after its issue), from the template. Lifecycle
  `draft`, `accepted`, `implemented`, `superseded` (never deleted). The `paths` field lists the code
  it governs; a PR touching those paths updates the spec or says `Spec-Unchanged: <reason>`.
- **When.** When writing a spec, when code under a spec changes, near files in `docs/specs/`.
- **Note.** `senior-mode check` and `status` warn about a spec drift (see [commands](commands.md)); it is never a
  gate, the reviewer judges it.

## `adr`

- **Rule.** One ADR per hard-to-reverse decision, in `docs/adr/NNNN-slug.md` (numbered from `origin/main` when committed), with at least two real
  alternatives and the bad consequences too. Status `proposed`, `accepted`, `superseded`. An accepted
  ADR is never edited: a new ADR supersedes it. No ADR for small reversible choices.
- **When.** For a hard-to-reverse choice, for every L ticket, near files in `docs/adr/`.

## `grill`

- **Rule.** Settle every open decision with the fewest questions. Gather facts first (through
  `scout`), never ask what the repository answers. Rounds of 3 to 4 questions, recommended option
  first, each option saying what it changes. Before closing, propose what you probably did not think
  of: risks, cheaper options, security, accessibility, cost. For non-technical users: no jargon,
  questions about outcomes.
- **When.** During framing, when a ticket has open questions, or when you say "let's frame" or
  "cadrons".

## `review`

- **Rule.** Review from the diff, the spec and the tests, on two axes. Spec: every criterion met and
  tested, nothing out of scope, spec and ADRs up to date. Standards: simplicity, design,
  correctness, security, tests, readability, history. A file matching a `protected` glob
  (`senior-mode protected`), or another sensitive area (migrations, security, auth, payments, CI,
  infrastructure, major upgrades, L tickets, ADRs), gets at best "approve, human merge" and the
  `needs-human` label.
- **Sections.** Loaded only when they apply:
  - the brief for the person who merges, always: what changes for users, risks and protected zones
    touched, what was tested and what was not, and questions to ask the author, in plain language;
  - security, always: injection, authorisation, secrets, unsafe shell, supply chain and data exposure,
    each finding with `file:line` and the fix, rated critical, high, moderate or low. A high or
    critical finding blocks: `senior-mode/review` is set to `failure`, never `success`. Moderate and
    low are reported only. Risks outside the diff are listed for triage, with no exploit detail;
  - UI, when the diff touches front-end files: screenshots of the touched pages if the project's
    Playwright is there, accessibility basics, component consistency, empty, loading and error
    states;
  - dependencies and data, when dependencies or data handling change: licences from the ecosystem's
    own tool, secrets and personal data in logs and exports, new third-party services. It flags
    facts for a human and does not rule on them;
  - your own, from [`review.sections`](configuration.md#project-review-sections).
- **Produces.** One PR comment with the verdict, the brief and `file:line` findings, and the status
  `senior-mode/review` (`success`, `pending` for a human merge, `failure`). Each finding ends with a stable
  `<!-- finding: <slug> -->`; one seen on two pull requests becomes a
  [knowledge note](configuration.md#knowledge-notes) in a separate `docs(knowledge): <slug>` pull request.
- **When.** For every pull request, from a fresh context. A pull request that touches a protected
  zone or closes an L ticket also gets the [`security`](agents.md#security) agent.

## `docs`

- **Rule.** Docs stay true because updating them is a step of delivery. After a merged pull request,
  change only what that change made stale: the README (usage, setup), `docs/architecture.md` (system
  overview, components, data flow, external services, links to new ADRs) and `docs/changelog.md` (one
  plain-language entry per pull request: what changed for users, date, link). It never invents a
  fact: unknowns become "To confirm".
- **Extra documents.** Documents listed under `docs.extra` in the configuration (a path and a one-line
  purpose each) are kept current too, with changes flagged for human review.
- **Produces.** Its own small `docs:` pull request, or new commits on the docs pull request already
  open; it never pushes to the default branch. Setup creates `docs/architecture.md` from a template
  (`en` or `fr`) when it is absent.
- **When.** After a merge (`run` and `next` call it), and when you say "update the docs" or
  "mets à jour la doc". Ask "what changed this week" for a digest of `docs/changelog.md`; nothing is
  written.
- **Note.** `docs/changelog.md` is for readers of the product; `CHANGELOG.md` is release-please's.

## Commands are skills too

`setup`, `frame`, `next`, `run`, `status` and `retro` are also skills. Only `frame` also starts on a plain
request; the others run when you type them. See [Commands](commands.md).
