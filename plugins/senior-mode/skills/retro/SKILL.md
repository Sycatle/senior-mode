---
name: retro
description: Weekly review of how the team worked - the facts of the week, then at most three process changes to approve. Use when the user asks for a retro, "rétro", "bilan de la semaine", "what went wrong this week", or how to stop repeating a mistake.
disable-model-invocation: true
---

# Retro

The learning step of the lifecycle. Facts first, then few and concrete changes. Nothing is edited
until the user says yes, except the knowledge pull request below.

## Gather

1. `senior-mode config get language` gives the language to answer in (`en` if it fails).
2. Run `senior-mode retro --json` (weekly; `--since 14d`, or `--iteration [<name>]`; it posts the health update). With
   no Project or config, tell the user to run `/senior-mode:setup`; if GitHub does not answer, say so
   and stop. It first files the open high or critical alerts as `security` issues; relay its stderr.
3. `knowledge` holds the notes to merge or delete and the agents' memory drafts
   (`.claude/agent-memory/<agent>/`, git-ignored): read each draft, cite one only if it recurs.
4. Read no more of the repository than a proposal needs.

## Present

In the configured language, plain words, skipping empty sections:

1. One sentence on the week ("five tickets done, two needed you").
2. Done, and the cycle time (median, worst).
3. What needed a human and why; failed or escalated runs; reopened tickets; failed local checks.
4. Causes (`failures`, `learning`): each ticket's `cause:<x>` label and evidence, and the improvement
   tickets filed or open (do not propose them again).
5. Sizes: tickets whose pull request outgrew their size (`over`); per size (`calibration`) the median
   and spread of hours, lines and tokens, the tickets far outside it, and a `recalibrate` hint (seen
   in two retros in a row, it becomes a proposal).

Give numbers as the output gives them. A missing start means no cycle time; absent run logs mean
nothing was run, not that nothing failed. Never invent a figure or a cause.

## Tidy the knowledge

When `knowledge` lists a merge, a deletion or a draft, follow `notes.md`: one pull request
`docs(knowledge): retro <date>`, then the drafts removed. Never the default branch.

## Propose

At most three changes, each the cheapest thing that would have prevented a repeated cost (a cause
seen at least twice, or once and expensive). Choose among:

- a pitfall in `CLAUDE.md` (non-derivable, one line);
- a protected glob in `.claude/senior-mode.json` (`protected`);
- a project check (`checks`) or hook that catches the mistake earlier;
- a ticket split rule when sizes keep being exceeded.

Each is an **issue draft**: title (what the user gets, in plain words), the facts that justify it
(ticket and pull request numbers), the change, the size. Show the drafts and ask which to create.
For each yes, `senior-mode issue create --title ... --body-file ... --size ... --priority ...`
(see `/senior-mode:frame` for the fields). If the week shows nothing worth changing, say so.

End with the one change you would do first.
