# Setup skill: reference

## No branch protection

`senior-mode setup github` prints `protection: NOT enforced` on a private repository of a Free
account or organization: GitHub offers no ruleset there, so anyone with push access can push to the
default branch, and the pre-push hook is the only gate. Relay it in plain words, with the two ways
out (make the repository public, or upgrade to Pro or Team and rerun setup), and get an explicit
acknowledgement before going on.

## Language

The language picks the templates `setup repo` writes (`en` or `fr`), so settle it before. Take it
from the user's `CLAUDE.md` (project, then `~/.claude/CLAUDE.md`), else from the language of the
conversation. Propose it as the recommended answer, never default to `en` silently. On a yes, set it:
`jq '.language = "<code>"' .claude/senior-mode.json`, written back to the file. Another language
than `en` or `fr` is kept as the reply language and uses the `en` templates.

## Repository follow-ups

1. If `setup repo` prints `missing:`, propose a tool for each (Biome to lint, Vitest to test),
   added in its own commit on a yes; then rerun it.
2. If it says `created from the skeleton`, fill it from the scout agent's commands, code map and
   pitfalls. If the repository has an `AGENTS.md`, `CLAUDE.md` imports it (`@AGENTS.md`): keep the
   instructions there and never copy them. If it reports over 80 lines, propose cuts.
3. Offer the status line.

## Status line

Offer a status line that shows the current ticket, the last check and the run in progress. It
is set for this project only (`.claude/settings.json` of this repository): it replaces the user's own
status line here, and their personal one stays untouched elsewhere. Say that before asking. On a yes,
run `senior-mode setup statusline`.
