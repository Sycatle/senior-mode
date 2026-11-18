# Contributing to senior-mode

Thanks for helping. senior-mode is built with its own workflow, so contributing here is also a short
tour of what the plugin asks of the projects that adopt it.

## Before you code

- Every change starts from an issue. Open one (bug or idea) and say what it gives the user; small
  fixes can go straight to a pull request that explains the problem.
- The design lives in [`docs/specs/0001-senior-mode.md`](docs/specs/0001-senior-mode.md) and the
  decisions in [`docs/adr/`](docs/adr/). A change of behaviour updates the spec in the same pull
  request; a new decision gets an ADR. An accepted ADR is never edited: a new one supersedes it.

## Set up

```sh
git clone https://github.com/Sycatle/senior-mode && cd senior-mode
git config core.hooksPath .githooks
```

You need `bash`, `jq`, `gh` (logged in), `shellcheck`, and Claude Code for `claude plugin validate`.
To try the plugin from your clone: `claude --plugin-dir plugins/senior-mode`.

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
- either the spec change, or a `Spec-Unchanged: <reason>` line.

A fresh-context `reviewer` agent reviews each pull request and sets `senior-mode/review`. Changes to
protected zones (CI, security, permissions, secrets, data migrations, major dependency upgrades, any
size L ticket or ADR) get the `needs-human` label and wait for a maintainer's explicit approval.

## Reporting a vulnerability

See [SECURITY.md](SECURITY.md). Please do not open a public issue for it.
