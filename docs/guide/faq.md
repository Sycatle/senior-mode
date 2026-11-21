# FAQ

Short answers to common questions about cost, GitHub plans, existing repositories, leaving senior-mode and French.

## What does it cost in tokens?

senior-mode spends strong models only where judgement matters ([ADR 0004](../adr/0004-model-routing.md)):

| Work | Model |
|---|---|
| Codebase facts (`scout`), GitHub bookkeeping (`ops`) | Haiku, low effort |
| Research, tests, code (`researcher`, `test-author`, `implementer`) | Sonnet, medium effort |
| Design and review (`architect`, `reviewer`) | Opus, high effort |

Other savings that ship today ([spec §15](../specs/0001-senior-mode.md#15-token-economy)):

- skills are short and load only when they match the task;
- the session greeting is a few lines, not a large document;
- facts come from `scout` instead of the main session reading files;
- board ids are cached in the config, so no agent looks them up again;
- `senior-mode check` shows only the last 20 lines of a failing check;
- each agent has a turn cap (`maxTurns`, from 15 to 60).

`run` gives each ticket its own fresh headless session.

## I have no GitHub Actions budget. Can I use it?

Yes. That is the default. In `local` mode the checks run on your machine before each push, and
`senior-mode publish` sends the result to GitHub as the `senior-mode/ci` status. No Actions minutes
are used, and setup disables existing workflows so they spend none either (the files are kept).
Why: [ADR 0006](../adr/0006-local-ci.md).

## My repository is private, on the free plan. What changes?

GitHub refuses rulesets and branch protection on private repositories of a Free account or
organization (HTTP 403, "Upgrade to GitHub Pro or make this repository public"). Setup reports it and
goes on: it skips the ruleset, sets `ci.mode` to `local` and records `github.protection: "none"` in
`.claude/senior-mode.json`.

You keep the board, labels, git hooks, the Bash guard and the statuses, but branch protection is
**not enforced on the server**: anyone with push access can push to the default branch, and GitHub
does not block a merge when `senior-mode/ci` or `senior-mode/review` is missing or red. Your options:

- make the repository public;
- upgrade to GitHub Pro or Team, then run `/senior-mode:setup` again to get the ruleset;
- accept it and keep the local gate (the pre-push hook and `senior-mode check`), checking the
  statuses yourself before merging. If a governance document describes your controls, say it this way.

## Can I use it on an existing repository?

Yes. Setup extends and never replaces:

- your files are kept: `CLAUDE.md` gets a Principles block appended, existing PR templates, issue
  forms, git hooks and release-please files stay as they are;
- your board fields keep their options and values, and GitHub's default `Todo` status becomes
  `Backlog`;
- your branch protection is untouched: the `senior-mode` ruleset adds to it;
- in `local` mode, your workflows are disabled, not deleted.

Run `/senior-mode:setup` and read the table of changes before you say yes.

## How do I turn it off, or leave senior-mode?

- **Pause it in Claude Code.** Use `/plugin` to disable or uninstall the plugin. Note that the Bash
  and secrets guards run in every repository while the plugin is enabled; the other hooks act only in
  repositories with `.claude/senior-mode.json`.
- **Leave it in one repository.** Undo what setup changed:
  - delete the `senior-mode` ruleset (repository Settings, Rules, Rulesets);
  - turn your workflows back on: `gh workflow enable <name>`;
  - `git config --unset core.hooksPath`, then remove `.githooks/` if you want;
  - remove `.claude/senior-mode.json`, the senior-mode lines in `.claude/settings.json`, and the
    Principles block in `CLAUDE.md`.

  The board, labels, specs, ADRs and release-please files are ordinary GitHub and repository content:
  keep or remove them as you like. Merge settings (rebase only) can be changed in repository Settings.

## What does an L ticket mean?

L is the largest size. A request is L when any one of these holds: a new subsystem, a data
migration, a public interface (API, schema, file format), a hard-to-reverse choice, or more than
about 400 changed lines. An L always goes through `/senior-mode:frame`: alternatives, at least one
ADR, a full spec, and an epic split into tickets of size M or less. A human accepts the spec and ADRs
before work starts. An L is never Ready itself; its sub-issues are. See [`triage`](skills.md#triage).

## Can I use it in French?

Partly, today:

- Add `"language": "fr"` to `.claude/senior-mode.json` before running setup. Setup then writes the
  French `CLAUDE.md` skeleton and Principles, PR template and issue forms. Templates already in place
  are kept, so set the language first.
- Skills read the language and write specs, ADRs, tickets, commits and answers in French. Commit
  types (`feat`, `fix`, ...) stay English keywords.
- "cadrons" is listed in the descriptions of `frame` and `grill`. Commands run only when typed,
  so type `/senior-mode:frame` to be sure framing starts.

There is no French companion plugin ([ADR 0013](../adr/0013-no-french-companion-plugin.md)): commands stay
in English, and French is served by trigger phrases and the `language` config key.
