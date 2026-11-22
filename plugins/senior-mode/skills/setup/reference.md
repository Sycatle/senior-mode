# Setup skill: reference

## No branch protection

`senior-mode setup github` prints `protection: NOT enforced` on a private repository of a Free
account or organization: GitHub offers no ruleset there, so anyone with push access can push to the
default branch, and the pre-push hook is the only gate. Relay it in plain words, with the two ways
out (make the repository public, or upgrade to Pro or Team and rerun setup), and get an explicit
acknowledgement before going on.

## Repository follow-ups

1. If `setup repo` prints `missing:`, propose a tool for each (Biome to lint, Vitest to test),
   added in its own commit on a yes; then rerun it.
2. If it created `CLAUDE.md`, fill the skeleton from the scout agent's commands, code map and
   pitfalls. If it reports over 80 lines, propose cuts.
3. Offer the status line.

## Status line

Offer a status line that shows the current ticket, the last check and the run in progress. It
replaces the user's own status line, so say that before asking. On a yes, run
`senior-mode setup statusline`.
