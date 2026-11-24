---
name: frame
description: Size and frame a request to change the product, then deliver or ticket it. Use on a plain request with no command ("je veux", "on devrait", "ajoute", "I want", "we should", "add") and on "frame", "cadrons", "plan a feature". Not for a question, a review, a status request or a bug report.
argument-hint: "<the idea, in a sentence or two>"
---

# Frame

Idea: $ARGUMENTS, else the user's request (ask in one line if neither). Write in the project language
(`senior-mode config get language`). Commands, formats, S and headless: `${CLAUDE_SKILL_DIR}/reference.md`.

1. **Size.** Apply skill `triage`; announce the size with its reason in one line before any work. A
   smaller size than the criteria allow is refused with the criterion; a larger is accepted.
2. **Questions.** Always one round, even for S: one batch of 3 to 4 questions, recommended option
   first, then only what stays open (skill `grill`). `docs/vision.md` against the idea: reference "Vision". Nobody to ask: take the recommended options and
   record them as assumed. Facts the files settle (`scout` agent) or the web (`researcher`) are never asked. Log each answer (reference "Decisions").
3. **S.** No spec: create its issue with the expected behaviour, then deliver it in this session
   through the `go` steps 4-9 (reference "Size S").
4. **Workspace (M, L).** `senior-mode frame start <slug>` makes a worktree and a branch `docs/<slug>`
   from `origin/main`; write there only. Default branch ahead of origin: stop, push it first.
5. **Design.** The spec is named after its anchor issue (the idea's, else one `ops` creates: the epic
   for L, the first slice for M). Give the `architect` agent the idea, the facts, every answer and the
   anchor. It writes `docs/specs/<anchor>-<slug>.md` (skill `spec`; M light, L full), an ADR per
   hard-to-reverse choice (skill `adr`, `proposed`), and returns vertical slices: title, size S or M,
   priority, milestone, criteria, test seams, blocked-by.
6. **Acceptance.** Show the problem, the criteria and each ADR's decision in a few lines and ask to
   accept: spec and ADRs become `accepted`, else stay `draft` / `proposed`. L needs an explicit yes.
   Nobody to ask: accept an M spec without ADR; an L spec or any ADR stays `draft` / `proposed`, the
   anchor gets `needs-human`, stop with a report.
7. **Tickets.** `ops` agent creates them (reference), blockers first. Rerunning is safe.
8. **Record.** Number the ADRs from `origin/main` (reference), commit (skill `commit`,
   `docs(spec): ...`), push, open a pull request.
9. **Ready.** Once merged and the spec accepted, apply skill `ready` to each slice; until then they
   wait in Backlog: say for what. Then ask "on enchaîne ?" (`/senior-mode:go`); `senior-mode status
   --json` with `.serve.running`: say the daemon takes them.

## End

At most five lines: decisions, files written, tickets with links in delivery order, what waits for
the user, then `grill`'s suggestions not turned into tickets, each with a recommendation.
