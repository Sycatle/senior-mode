# Knowledge note from a pitfall: reference

Read before opening the pull request when the session hit a constraint the code does not show. The
format is in `docs/guide/configuration.md#knowledge-notes`; `senior-mode check` validates it.

## When to write one

Write a note when you retried the same step twice or more because of a constraint nobody could read in
the code: an import order a tool reorders, a side effect on import, a hidden coupling, a command that
only works with a flag, a generated file. Not for a typo, a flaky run, a mistake of your own, or
anything the code, `CLAUDE.md` or an ADR already says. Without such a pitfall, add no note.

## What to write

1. List the candidates. Keep the 2 most useful for the next agent, never more than 2 per pull
   request; the others are dropped, not filed elsewhere.
2. Look in `docs/knowledge/` for a note with the same `paths` and the same `kind`. If there is one,
   edit it and set `verified` to today, after reading it against the code; do not add a second.
3. Otherwise add `docs/knowledge/<slug>.md`, `<slug>` kebab-case, one fact per note:
   - `paths`: the files the pitfall is about, as narrow globs.
   - `verified`: today.
   - `origin`: your ticket, `"#<n>"`.
   - `kind`: `pitfall`.
   - Body: a title naming the trap, then what breaks, why, and what to do. Under 40 lines.
4. Run `senior-mode check`: the `knowledge` step must pass. The note goes in the same pull request
   as the code that taught it, in its own `docs(knowledge):` commit.
