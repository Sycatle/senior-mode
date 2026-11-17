---
name: frame
description: Turn an idea into decisions, a spec, ADRs and ready tickets on the board. Use when the user says "frame", "let's frame" or "cadrons", or asks to plan a feature.
disable-model-invocation: true
argument-hint: "<the idea, in a sentence or two>"
---

# Frame

Idea: $ARGUMENTS (ask for it in one line if empty). Write to the user in the project language
(`senior-mode config get language`).

1. **Size.** Apply skill `triage`. Size S needs no framing: say so and stop.
2. **Facts.** Ask the `scout` agent what the repository already settles: stack, related code, specs,
   ADRs, open issues, milestones (`gh api repos/{owner}/{repo}/milestones`). Never ask the user
   any of it.
3. **Decisions.** Run skill `grill` until no open decision blocks the spec. When an option depends
   on outside facts (a library, a service, a price, a limit), get them from the `researcher` agent
   before the round, and show the sources in the options.
4. **Design.** Give the `architect` agent the idea, the facts and every answer. It writes the spec
   (skill `spec`; M light, L full), an ADR per hard-to-reverse choice (skill `adr`, `proposed`),
   and returns vertical slices: title, size S or M, priority, milestone, acceptance criteria,
   test seams, blocked-by.
5. **Acceptance.** Show the user the problem, the criteria and each ADR's decision in a few lines,
   and ask to accept. Accepted: spec `accepted`, ADRs `accepted`. Otherwise they stay `draft` and
   `proposed`; a size L is never accepted without an explicit yes.
6. **Tickets.** Have the `ops` agent create them, blockers first, one call each:
   `senior-mode issue create --title <t> --body-file <f> --size <S|M|L> --priority "<option>"
   --milestone "<title>" --type <feature|bug|task|chore> [--blocked-by <n>]... [--parent <n>]`.
   The body holds what it gives (plain words), a link to the spec, the acceptance criteria as
   Given / When / Then and the test seams. A size L first gets an epic issue (size L, the spec's
   summary); every slice takes `--parent <epic>`. A missing milestone is created first with
   `gh api repos/{owner}/{repo}/milestones -f title=<title>`. Rerunning the command is safe: an
   open issue with the same title is reused.
7. **Ready.** When the spec is accepted, apply skill `ready` to each slice. Otherwise they stay in
   Backlog until the user accepts.
8. **Record.** Commit the spec and ADRs (skill `commit`, `docs(spec): ...`) on a branch
   `docs/<first issue>-<slug>`, open a pull request and let it merge like any other.

## End

At most five lines: decisions, files written, tickets with links in delivery order, what waits for
the user. Then the proactive suggestions from `grill` that were not turned into tickets, each with a
recommendation. "go" then starts `/senior-mode:next`.
