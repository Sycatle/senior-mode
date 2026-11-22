---
name: frame
description: Turn an idea into decisions, a spec, ADRs and ready tickets on the board. Use when the user says "frame", "let's frame" or "cadrons", or asks to plan a feature.
disable-model-invocation: true
argument-hint: "<the idea, in a sentence or two>"
---

# Frame

Idea: $ARGUMENTS (ask for it in one line if empty). Write to the user in the project language
(`senior-mode config get language`). Commands and formats: `${CLAUDE_SKILL_DIR}/reference.md`.

1. **Size.** Apply skill `triage`. Size S needs no framing: say so and stop.
2. **Workspace.** `senior-mode frame start <slug>` makes a worktree and a branch `docs/<slug>` from
   `origin/main`; write everything below there, not in the main checkout. If it says the default
   branch is ahead of origin, stop: those commits must be pushed or merged first.
3. **Facts.** Ask the `scout` agent what the repository files settle (stack, related code, specs,
   ADRs); read open issues and milestones yourself (reference). Never ask the user any of it.
4. **Decisions.** Run skill `grill` until no open decision blocks the spec. Options that depend on
   outside facts (library, service, price, limit): get them from the `researcher` agent first and
   show the sources.
5. **Design.** The spec is named after its anchor issue: the one the idea came from, else one `ops`
   creates now (the epic for L, the first slice for M). Give the `architect` agent the idea, the
   facts, every answer and the anchor number. It writes `docs/specs/<anchor>-<slug>.md` (skill
   `spec`; M light, L full), an ADR per hard-to-reverse choice (skill `adr`, `proposed`), and returns
   vertical slices: title, size S or M, priority, milestone, acceptance criteria, test seams, blocked-by.
6. **Acceptance.** Show the problem, the criteria and each ADR's decision in a few lines and ask to
   accept: spec and ADRs become `accepted`, else they stay `draft` and `proposed`. Size L needs an
   explicit yes.
7. **Tickets.** Have the `ops` agent create them as in the reference, blockers first, one call each.
   Rerunning is safe: an open issue of the same title is reused, Status kept, body replaced.
8. **Record.** Number the ADRs from `origin/main` (reference), commit the spec and ADRs (skill
   `commit`, `docs(spec): ...`), re-check the numbers, push, open a pull request.
9. **Ready.** Once that pull request is merged and the spec accepted, apply skill `ready` to each
   slice; until then they wait in Backlog: say for what.

## End

At most five lines: decisions, files written, tickets with links in delivery order, what waits for
the user. Then `grill`'s proactive suggestions not turned into tickets, each with a recommendation.
"go" then starts `/senior-mode:next`.
