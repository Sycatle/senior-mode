# Getting started

Install senior-mode, adopt a repository with `/senior-mode:setup`, then frame your first idea.

## Requirements

- **Claude Code**, where the plugin runs.
- **git**, and a repository with an `origin` remote on GitHub. If you have none, setup offers to
  create one (private by default) and waits for your yes.
- **The GitHub CLI `gh`**, logged in (`gh auth login`), with the `project` scope. Add it with:

  ```
  gh auth refresh -s project
  ```

  It opens a browser. Setup checks this and asks you to run it if the scope is missing.
- **jq**. The `senior-mode` script, the hooks and the git hooks read JSON with it.
- **Node 22 or later**, only to publish releases (`senior-mode release` runs release-please through `npx`).

## Install

In Claude Code:

```
/plugin marketplace add Sycatle/senior-mode
/plugin install senior-mode@senior-mode
```

The plugin adds commands (`/senior-mode:setup`, `/senior-mode:frame`), discipline skills, an agent
team, hooks, and a `senior-mode` script that Claude can call from its Bash tool. You can call the
script yourself from the Claude Code prompt with a leading `!`, for example `! senior-mode check`.

## Adopt a repository

Open Claude Code in the repository and run:

```
/senior-mode:setup
```

### The consent step

Before changing anything, setup:

1. checks that the folder is a git repository with a GitHub `origin`, and that `gh` is logged in
   with the `project` scope;
2. asks one question: where the checks run (see below);
3. shows a short table of what will change on GitHub, and waits for your yes.

### What changes on GitHub

`senior-mode setup github` does the following:

- **Project board.** It finds the Project linked to the repository (or one with the repository's
  name), or creates it. It makes sure the fields `Status` (Backlog, Ready, In progress, In review,
  Done), `Priority` (P0 now, P1 next, P2 later, P3 someday), `Size` (S, M, L) and `Severity` (critical, high,
  moderate, low) exist. Options and values already there are kept. Severity is a tie-break within a
  Priority, not a priority: a critical ticket moved by hand to P1 still comes after a P0. A project
  created before Severity gets the field by rerunning `senior-mode setup github`.
- **Labels.** `needs-human`, `needs-info`, `blocked`, `security` (on risks filed with `--severity`). On a personal account, also `type:feature`,
  `type:bug`, `type:task` and `type:chore` (organizations use issue types).
- **Merges.** Rebase merges only; branches are deleted after merge.
- **Ruleset.** A ruleset named `senior-mode` on the default branch: pull requests only, rebase,
  linear history, no deletion or force-push, and three required statuses, `senior-mode/ci`,
  `senior-mode/review` and `senior-mode/security`, on an up-to-date branch, and code owner review of the [protected
  zones](autonomy.md#code-owners) (setup writes `.github/CODEOWNERS` for you to commit; the owner
  merges those pull requests by hand). It adds to your existing protection and does not
  rewrite it. Admins can bypass it with `gh pr merge --admin`; agents cannot (see
  [Autonomy](autonomy.md)). On a private repository of a GitHub Free account or organization, GitHub
  refuses rulesets: setup says so, switches to `local` mode and records `github.protection: "none"`.
  Nothing then stops a push to the default branch on the server, only your pre-push hook; setup asks
  you to acknowledge it. See the [FAQ](faq.md#my-repository-is-private-on-the-free-plan-what-changes).
- **Workflows.** In `local` mode, the repository's GitHub Actions workflows are disabled. The files
  are kept; `gh workflow enable <name>` turns one back on.

### What changes in the repository

`senior-mode setup repo` adds, and keeps what you already have:

- `.claude/senior-mode.json`, the project config, with the board ids cached and the check list
  (see [Configuration](configuration.md));
- git hooks in `.githooks/` (`commit-msg`, `pre-push`), and `core.hooksPath` set to `.githooks`;
- a `Principles` block in `CLAUDE.md`, or a `CLAUDE.md` skeleton that Claude fills from the code;
- a pull request template and two issue forms (feature, bug);
- `docs/architecture.md`, a system overview from a template that the `docs` skill keeps current;
- permissions in `.claude/settings.json`;
- `release-please-config.json` and `.release-please-manifest.json`;
- in `actions` mode, `.github/workflows/senior-mode.yml`.

With a `package.json`, the `node` preset reads your scripts. Otherwise setup asks once how to lint,
typecheck, test and build. If a linter or test runner is missing, it proposes one (Biome, Vitest)
in its own commit, only if you say yes.

### CI mode: local or actions

| Mode | Where the checks run | Cost |
|---|---|---|
| `local` (default) | On your machine: before each push (git hook) and with `senior-mode check`. `senior-mode publish` sends the result to the pull request as `senior-mode/ci`. | Free. No GitHub Actions minutes. |
| `actions` | Also on GitHub Actions, through `.github/workflows/senior-mode.yml`, which sets `senior-mode/ci`. | Spends your Actions budget. |

The check list is the same in both modes. Why local is the default: [ADR 0006](../adr/0006-local-ci.md).

### Re-running to repair

Setup is safe to run again. It repairs and never duplicates: missing fields and labels come back,
the ruleset is updated, the Principles block is refreshed, and files you edited are kept. Run it
again after an error, or to switch CI mode:

```
/senior-mode:setup
```

The script form, if you prefer: `senior-mode setup github --ci actions`, then `senior-mode setup repo`.

## Your first framing

Run `frame` with your idea in a sentence or two:

```
/senior-mode:frame let customers export their invoices as CSV
```

Claude first sizes the idea (S, M or L). A size S needs no framing, and Claude says so. For M and L,
it reads the repository and your open issues, then asks you a few rounds of 3 to 4 questions, each
with a recommended answer. It writes a spec and, for hard-to-reverse choices, ADRs. It asks you to
accept them, creates the tickets on the board and opens a pull request with the documents.

While framing, Claude may only write under `docs/`. Starting another senior-mode command ends the
framing session; so does `! senior-mode frame end`.

Details: [`frame`](commands.md#frame). Next: [A typical day](a-typical-day.md).
