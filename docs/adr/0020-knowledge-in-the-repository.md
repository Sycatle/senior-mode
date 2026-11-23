---
id: 0020
title: Path-scoped knowledge notes and a vision file live in the repository
status: accepted
spec: 325
amends: 0002
---

## Context

ADR 0002 puts durable knowledge in the repository (specs, ADRs, `CLAUDE.md`) and state in GitHub. It
says nothing about the small facts a long-lived project accumulates: a pitfall in the billing code, a
convention a reviewer keeps repeating, why a module is shaped as it is. Today they go to the agents'
private `memory: project`, which no human reads, no pull request reviews, no `check` validates and
that is gone with the machine. A project developed by agents over months needs those facts in front of
the next agent, scoped to what it is about to touch, and it needs them to stay true.

## Decision (owner, 2026-11-23)

- **Knowledge notes** are Markdown files in `docs/knowledge/`, one fact each, with front matter
  `paths` (globs the note is about), `verified` (date), `origin` (the ticket, or `retro`) and `kind`.
  They are small, validated by `check`, and reach an agent through the briefing that `context` builds
  from the ticket's Paths (spec 325 §2 and §3).
- **`docs/vision.md`** holds the project's goals and non-goals; milestones cite a goal. A human owns
  it: it is a protected path.
- **ADRs and specs** carry `paths` so the briefing can find them.
- **Agent private memory** (`memory: project`, `.claude/agent-memory/`) is a draft. `retro` promotes a
  draft to a note through a pull request or drops it. Nothing durable lives only there.
- **State still lives in GitHub** (ADR 0002): notes hold knowledge, not plans, progress or journals.
  What 0002 says about "no backlog, plan or journal file" is unchanged; a note is not a journal entry.
- Every change to a note is a pull request, like any other documentation.

This amends ADR 0002: its "durable knowledge lives only in the repository" now names notes and the
vision file next to specs and ADRs, and the plugin may create `docs/knowledge/` and `docs/vision.md`.

## Alternatives considered

- **Agent memory (`memory: project`) as the store:** zero setup and already there, but private to one
  agent role, unreviewed, unversioned with the code, not shared with humans or other agents, and with
  no way to know a fact went stale. Kept only as the draft layer that feeds the notes.
- **GitHub wiki:** readable by non-developers, but a separate repository with no pull request flow, no
  link to code paths, no atomic change with the code that makes a fact true or false, and no offline
  use. It would split durable knowledge across two places, which 0002 avoided for specs.
- **Semantic index (embeddings, vector store):** finds text by meaning without front matter. It adds a
  service or a model to run, gives results that vary between runs, cannot say why a note was chosen
  and cannot say a note is stale. Path scoping is deterministic, cheap and auditable; a project that
  outgrows it can add an index later behind the same briefing.
- **Everything in `CLAUDE.md`:** loaded in every session whatever the ticket, so it grows without a
  bound and the useful lines drown. It stays limited to commands, the code map and pitfalls that
  hold for the whole repository (80 lines).

## Consequences

- More files in the repository; the size limit, `check`, the freshness rules and the gardening tickets
  keep them honest (spec 325 §2, §5).
- A wrong note misleads agents until someone fixes it; the age shown next to each note and the
  `verified` date make a doubtful note visible.
- The briefing is deterministic and testable; relevance beyond path overlap is left to the scout
  agent.
- Existing repositories adopt the layout through a migration that changes nothing without a pull
  request (spec 325 §9).
