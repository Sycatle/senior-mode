---
name: status
description: Show where the project stands in plain words - done, in progress, blocked, waiting for a human, next, release. Use when the user asks for the status, "état", "où on en est", "point d'avancement", "what's the state", or a digest for someone who is not technical ("résumé de la semaine").
disable-model-invocation: true
---

# Status

A cheap read of the board, in the project's language. Nothing here edits anything (`--publish` posts the health as a Project status update; only on request).

## Run

1. `senior-mode config get language` gives the language to answer in (`en` if it fails).
2. Run `senior-mode status`. It reports what is new since the last plain run and moves that mark, so
   do not run it twice for one answer.
   - A digest for someone outside the team ("this week", "for the client"): `senior-mode status
     --since 7d` (or `2w`, `12h`); it does not move the mark.
   - Needs figures or a list to act on: add `--json`.
   - If it says there is no Project or no config, tell the user to run `/senior-mode:setup`; if it
     cannot reach GitHub, say so and stop.
3. For the next tickets to deliver, `senior-mode status` already lists the top three; `senior-mode
   pick` gives the whole ordered list.

## Answer

Summarise in the configured language, in this order, skipping empty sections:

1. One sentence: how things stand (for example, "two tickets in progress, one waiting for you").
2. **Needs you** first: pull requests with `needs-human` or failing statuses, tickets with missing
   information. Say what to do for each ("review and merge #20", "answer the question on #19").
   A "Board drift" section: closed tickets not Done can be repaired by the user with `senior-mode
   status --fix`; the others need their decision (close it, resume it or move it back).
   A "Spec drift" section: an accepted spec whose code changed with no `Spec-Unchanged:`; suggest
   updating the spec or adding the line to the pull request.
3. Done since last time, in progress, in review, blocked.
   A "Progress" section (tickets closed / total per goal, milestone, epic): one line per goal; a
   drift flag ("no Goal: line", "no spec") is fixed by editing the milestone or the epic.
4. Next ticket and the release state.

Keep ticket numbers, drop tool vocabulary. For a digest, write for a reader who has never opened the
board: what users can now do, what is coming, what is stuck and why. No pull request numbers, no
statuses, no jargon. Never invent a date or a figure the output does not give.

When the output says "Daemon: serve is running", say the daemon is delivering. When it says "Retro
due", offer the weekly retro; on a yes, invoke skill `retro`.

End with one suggested next step when there is an obvious one (`/senior-mode:go`, a review to do).

## Watching

The user can keep a live view in a terminal or a tmux pane: `senior-mode status --watch` (every 30
seconds, `--watch 60` for another interval). Mention it once if they ask for something live.
