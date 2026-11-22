# Contributing to senior-mode

Thanks for helping. senior-mode is built with its own workflow, so contributing here is also a short
tour of what the plugin asks of the projects that adopt it.

## Before you code

- Every change starts from an issue. Open one (bug or idea) and say what it gives the user; small
  fixes can go straight to a pull request that explains the problem.
- The design lives in [`docs/specs/0001-senior-mode.md`](docs/specs/0001-senior-mode.md) and the
  decisions in [`docs/adr/`](docs/adr/). A change of behaviour updates the spec in the same pull
  request; a new decision gets an ADR. An accepted ADR is never edited: a new one supersedes it.
- A new skill must map to a step of the lifecycle and a team role (spec section 8, ADR 0009). A
  practice that fits no step is a section of an existing skill, or it stays out. Client, stack-vendor
  or regulation specifics do not belong in the core: they go through the extension points (ADR 0010).

## Set up

```sh
git clone https://github.com/Sycatle/senior-mode && cd senior-mode
git config core.hooksPath .githooks
```

You need `bash` 4.4 or later, `jq`, `gh` (logged in), `shellcheck`, and Claude Code for `claude plugin validate`.
To try the plugin from your clone: `claude --plugin-dir plugins/senior-mode`.

## Working on a ticket

`plugins/senior-mode/bin/senior-mode start <issue>` makes the branch and a worktree for it in
`.git/senior-mode/worktrees/<issue>` of your clone (never a sibling folder, and neither are the worktrees of `frame start` and of the docs session of `run`); `senior-mode status` shows
the path of each ticket in progress. Open it with `code .git/senior-mode/worktrees/<issue>`, or `cd`
there and start `claude`. A ticket started before this, in a sibling `<repo>-<issue>` folder, keeps it.

## Checks run on your machine

There is no hosted CI here (ADR 0006): the project has no GitHub Actions budget, and its workflows
are disabled. The same check list runs locally instead.

- The pre-push hook runs `plugins/senior-mode/bin/senior-mode check`: plugin manifests, shellcheck,
  skill size (a `SKILL.md` stays under 3072 bytes), the agent team, every `test-*.sh`, and commit
  subjects.
- After pushing, `plugins/senior-mode/bin/senior-mode publish` sets the `senior-mode/ci` status on
  the pushed commit. It needs a clean tree and a check recorded on that tree.
- Pull requests to `main` need `senior-mode/ci` and `senior-mode/review` on an up-to-date branch,
  linear history, and are merged by rebase.
- From a fork, `publish` can only write to your fork, so it does not reach your pull request. Run
  the check and paste its summary in the pull request; a maintainer reads the diff first (the check
  runs your code with their GitHub token), then reruns it on your head commit and publishes the
  status.

## Commits

- [Conventional Commits](https://www.conventionalcommits.org/), atomic: one logical change that
  builds and passes on its own. The subject says what, the body says why.
- Tests go in the same commit as the code they cover. Fix a bug with a regression test.
- Prompts, docs, commits, issues and pull requests are in English.

## Pull requests

The body gives:

- the issue it closes (`Closes #n`);
- what it gives, in plain words;
- the red run: the output of the new tests failing before the fix;
- what you verified, and what you could not;
- for a command, skill or hook: the dogfooding evidence (ADR 0011), that is the real `claude -p`
  session you ran on the sandbox repository (`Sycatle/senior-mode-sandbox`), what you ran and what
  you saw. `check` alone does not prove behaviour, and a PR without this is not merged. The sandbox
  is private, so an external contributor cannot run it: a maintainer reads the diff, runs the session
  on your head commit and records it in the PR (see below);
- either the spec change, or a `Spec-Unchanged: <reason>` line.

A fresh-context `reviewer` agent reviews each pull request and sets `senior-mode/review`. Changes to
protected zones (CI, security, permissions, secrets, data migrations, major dependency upgrades, any
size L ticket or ADR) get the `needs-human` label and wait for a maintainer's explicit approval.

### Dogfooding external pull requests

The sandbox is private, so, like `publish` for forks, the maintainer does this step. They read the
diff first (the session runs your code with their credentials), then run the `claude -p` session on
the sandbox against your head commit and record it in the PR: what they ran, what they saw, and the
commit it ran on. A push after that makes the record stale and the session runs again. Until then,
write in the PR what the session should exercise.

## Reporting a vulnerability

See [SECURITY.md](SECURITY.md). Please do not open a public issue for it.
