# Setup skill: reference

## No branch protection

`senior-mode setup github` prints `protection: NOT enforced` on a private repository of a Free
account or organization: GitHub offers no ruleset there, so anyone with push access can push to the
default branch, and the pre-push hook is the only gate. Relay it in plain words, with the two ways
out (make the repository public, or upgrade to Pro or Team and rerun setup), and get an explicit
acknowledgement before going on.

## Board

With no Project, `senior-mode setup github` copies the template Project (`board.template`): views,
fields and built-in workflows come with the copy. It then ensures the fields Status, Priority, Size,
Severity and Paths (text), keeping existing options. Relay `board: the copy lacks ...` (views to add
by hand, workflows to turn on in the Project's Workflows tab: no API does either). An existing Project is
never replaced: on `board: the Project lacks ...`, say what is missing and offer `--migrate`.

## Scanners

`senior-mode setup github` turns on Dependabot alerts, secret scanning and push
protection, and prints `security: <feature>: on` or `not enabled (<reason>)` for each: relay every
`not enabled` in plain words (the plan or the token refuses it; setup went on). It leaves Dependabot security updates off and writes no `.github/dependabot.yml` (GitHub cannot limit
them to high and critical severity, so alerts become issues only); if the project has its own, setup
prints `dependabot.yml: untouched`.

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

`setup repo` adds `.claude/agent-memory/` to `.gitignore` (printed once). The agents' project memory
is written in the checkout the session runs in, never in a pull request, so it is kept on the machine
and the tree stays clean; `retro` reads it there.

## Status line

Offer a status line that shows the current ticket, the last check and the run in progress. It
is set for this project only (`.claude/settings.json` of this repository): it replaces the user's own
status line here, and their personal one stays untouched elsewhere. Say that before asking. On a yes,
run `senior-mode setup statusline`.

## Without a human

Nobody can answer in `claude -p` or a session with `SENIOR_MODE_RUN=1`. Take the recommended option
of each reversible question and say so in the report: checks `local`, the detected language, no
status line (it edits settings). Never acknowledge `protection: NOT enforced`: finish the rest,
report that the gap awaits a human, stop there. The permissions that `setup repo` writes to
`.claude/settings.json` are ignored by a headless session in a workspace Claude Code does not trust
yet: open the folder interactively once and accept the trust prompt, or pass the permissions on the
command line.
