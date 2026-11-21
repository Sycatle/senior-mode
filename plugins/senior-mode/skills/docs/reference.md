# Docs skill: reference

## What a change makes stale

| The change... | Update |
|---|---|
| alters install, run, configuration or a command | README (usage, setup) |
| adds or removes a service, package, job or app | `docs/architecture.md` Components |
| changes how data moves, a queue, an API, a datastore | `docs/architecture.md` Data flow |
| adds or swaps a provider or an outside API | `docs/architecture.md` External services |
| adds an ADR | link in `docs/architecture.md` Decisions |
| changes what users see or can do | `docs/changelog.md` |

A dependency name is a hint, not a fact: write "To confirm: is X used in production?".

## `docs/architecture.md`

Sections, stable: Overview, Components, Data flow, External services, Decisions (French: Vue
d'ensemble, Composants, Flux de données, Services externes, Décisions). Short sentences or lists. Say
which file or ADR a fact comes from, so a reader can check it. Unknowns are lines starting
`To confirm:` (French `À confirmer :`) with the question.

## `docs/changelog.md`

```
# Changelog

## 2026-11-21
- **Users can export their invoices.** A new "Export" button on the invoice list downloads a CSV.
  ([#42](https://github.com/owner/repo/pull/42))
```

- French title: `# Journal des changements`. Dates are merge dates (`YYYY-MM-DD`), newest first, one
  `##` per date, one bullet per PR.
- Bold sentence: the result for users. Then one or two plain sentences: no file names, no ticket jargon.
- A fix says what was wrong and that it is fixed. A breaking change says what users must do.
- The newest PR number is where the next run resumes.

## Extra documents (`docs.extra`)

```json
"docs": { "extra": [ { "path": "docs/runbook.md", "purpose": "How to operate and restore the service" } ] }
```

The purpose line says what the document must stay true about. Edit only the sections the change
affects; leave the author's structure and wording alone. Core adds no template or heading of its
own: what such a document contains is the project's business.

## The docs pull request

- Branch `docs/after-pr-<last number>`; subject `docs: update the docs after #<n>`; a second commit
  `docs(extra): ...` when extra documents change.
- Body, in the project language: what changed in each file; "Facts added and their source"; "To
  confirm" items still open; PRs skipped and why; "For human review" for extra documents.
- The `Closes #` line says none: this is documentation, not a ticket.

## Callers

`run` calls this skill once at the end of a run for every PR the run merged; `next` calls it after the
user merges the ticket's PR. Neither waits for the docs PR.
