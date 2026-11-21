---
name: retro
description: Weekly review of how the team worked - the facts of the week, then at most three process changes to approve. Use when the user asks for a retro, "rétro", "bilan de la semaine", "what went wrong this week", or how to stop repeating a mistake.
disable-model-invocation: true
---

# Retro

The learning step of the lifecycle. Facts first, then few and concrete changes. Nothing here edits
anything until the user says yes.

## Gather

1. `senior-mode config get language` gives the language to answer in (`en` if it fails).
2. Run `senior-mode retro --json` (weekly; `--since 14d` or `4w` for another period). If it
   says there is no Project or config, tell the user to run `/senior-mode:setup`; if GitHub does not
   answer, say so and stop.
3. Do not read more of the repository than a proposal needs.

## Present

In the configured language, plain words, skipping empty sections:

1. One sentence on the week (for example, "five tickets done, two needed you").
2. Done, and the cycle time (median, worst): is it a few hours or several days?
3. What needed a human and why; failed or escalated runs; reopened tickets; failed local checks.
4. Sizes: tickets whose pull request outgrew their size (`over`).

Give numbers as the output gives them. A missing start means no cycle time for that ticket; absent
run logs mean nothing was run, not that nothing failed. Never invent a figure or a cause.

## Propose

At most three changes, each the cheapest thing that would have prevented a repeated cost. Look for a
cause seen at least twice, or once and expensive. Choose among:

- a pitfall in `CLAUDE.md` (non-derivable, one line);
- a protected glob in `.claude/senior-mode.json` (`protected`);
- a project check (`checks`) or hook that catches the mistake earlier;
- a ticket split rule when sizes keep being exceeded.

Each is an **issue draft**: title (what the user gets, in plain words), the facts that justify it
(ticket and pull request numbers), the change, the size. Show the drafts and ask which to create.
For each yes, `senior-mode issue create --title ... --body-file ... --size ... --priority ...`
(see `/senior-mode:frame` for the fields). Edit no config or file, and open no pull request, for a
change the user has not approved. If the week shows nothing worth changing, say so; do not pad.

End with the one change you would do first.
