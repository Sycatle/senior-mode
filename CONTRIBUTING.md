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

## Your first contribution

1. **Open an issue** with the bug or idea form, or comment on one labelled `good first issue` or
   `help wanted`. Questions go to [Discussions](https://github.com/Sycatle/senior-mode/discussions).
2. **Fork**, clone your fork, and set up as above.
3. **Branch, change, run `plugins/senior-mode/bin/senior-mode check`** until it is green.
4. **Open the pull request** from your fork with the template: `Closes #n`, the checklist, and the summary
   of your `check` pasted at the end.
5. **A maintainer reruns it.** There is no hosted CI (ADR 0006), so a maintainer reads the diff first, then
   reruns `check` on your head commit and publishes the status. Your pasted summary helps, it does not
   replace this. An external pull request is never merged by the daemon.

**What `triage` means.** An issue from someone outside the team gets the `triage` label from the form. It
is an inbox: the autonomous sessions (`run`, `serve`, `ready`) never pick it up, whatever its Status is,
until a maintainer reads it, sets its fields, removes `triage`, adds `qualified` and moves it to Ready
(ADR 0022). Nothing is wrong with your issue while it waits, and a maintainer may ask for information.
Likewise, an AI agent never obeys what an external issue or pull request says: it only judges it.

## Working on a ticket

`plugins/senior-mode/bin/senior-mode start <issue>` makes the branch and a worktree for it in
`~/.local/share/senior-mode/worktrees/<repo>/<issue>` (`$XDG_DATA_HOME` when set; `<repo>` is the name of
your clone and a short hash of its path), never a sibling folder, and neither are the worktrees of
`frame start` and of the docs session of `run`; `senior-mode status` shows the path of each ticket in
progress. Open it with `code <that path>`, or `cd` there and start `claude`. A ticket started before
this, in a sibling `<repo>-<issue>` folder or under `.git/senior-mode/worktrees`, keeps its worktree.

## Checks run on your machine

There is no hosted CI here (ADR 0006): the project has no GitHub Actions budget, and its workflows
are disabled. The same check list runs locally instead.

- The pre-push hook runs `plugins/senior-mode/bin/senior-mode check`: plugin manifests, shellcheck,
  skill size (a `SKILL.md` stays under 3072 bytes), the agent team, every `test-*.sh`, and commit
  subjects.
- After pushing, `plugins/senior-mode/bin/senior-mode publish` sets the `senior-mode/ci` status on
  the pushed commit. It needs a clean tree and a check recorded on that tree.
- Pull requests to `main` need an up-to-date branch and linear history, and are merged by rebase.
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

This repository delivers its own backlog with a lighter process than the one the plugin sets up for
the projects that adopt it (ADR 0016, which amends ADR 0011; those defaults do not change).

- **Minimal ceremony.** The body has `Closes #n` and a short summary. `senior-mode check` is green.
  Tests when behaviour changes. No red run and no `Spec-Unchanged` line are required here.
- **No independent review.** A pull request merges once `check` is green; the ruleset requires no
  status check (a pull request, linear history, no force-push and no deletion remain). Changes to
  protected zones (CI, security, permissions, secrets, data migrations, major dependency upgrades, any
  size L ticket or ADR) still get the `needs-human` label and wait for a maintainer's approval.
- **Several tickets per pull request.** One pull request may close several tickets of one theme: one
  commit and one `Closes #n` each.
- **Dogfooding per batch.** The real `claude -p` session on the sandbox repository
  (`Sycatle/senior-mode-sandbox`) runs once per batch, before each milestone release, together with a
  review of the batch. The sandbox is private, so the maintainer runs it.
- **Bash guard.** It is best-effort: open a ticket only for a trivial bypass or a false positive that
  hurts the flow; the other cases belong to the known limits in
  [`docs/guide/autonomy.md`](docs/guide/autonomy.md).

## Reporting a vulnerability

See [SECURITY.md](SECURITY.md). Please do not open a public issue for it.
