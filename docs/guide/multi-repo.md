# Products of several repositories and organizations

This page is for the owner of a product that lives in several repositories (an API, a web app, a mobile app, an
infrastructure repository) or of a GitHub organization that wants to set its conventions once. A repository that does
none of this is unaffected: no new key is needed, and nothing below changes how one repository works.

The design is [spec 329](../specs/329-multi-repo-products.md) and [ADR 0026](../adr/0026-multi-repo-products.md). The
guide describes what the plugin does today. Each part below says **Available** or **Planned**, with the ticket that will
deliver it; a planned part is the design, not a behaviour you can rely on yet. The proof of the whole on a sandbox
organization is #461, and paid-plan organization features are documented here, not proven live.

| Part | State |
|---|---|
| [Attach a repository to a shared Project](#attach-a-repository-to-a-shared-project) | Available |
| [The served set and `serve.scope`](#the-served-set-and-servescope) | Planned (#451, #402, #455, #453) |
| [Naming and filing tickets across repositories](#naming-and-filing-tickets-across-repositories) | Planned (#450) |
| [Cross-repo epics](#cross-repo-epics) | Planned (#457, #399) |
| [The organization layer](#the-organization-layer) | Partly available: the layer file is read, the `.github` repository is planned (#400, #459) |
| [`setup org`](#setup-org) | Available; organization rulesets detection planned (#738) |
| [`status --all`](#status---all) | Planned (#403) |

## Attach a repository to a shared Project

One Project can hold the items of several repositories of its owner, with the built-in Repository field telling them
apart. `setup github --project` attaches the current repository to an existing Project instead of finding or copying one:

```bash
senior-mode setup github --project 7 --dry-run   # prints the fields, the link and the config; changes nothing
senior-mode setup github --project 7 --home acme/api
```

- It checks the fields `Status`, `Priority`, `Size`, `Severity` and `Paths`. A missing field is created. A missing option
  of an existing field (such as `In review` in `Status`) is reported with where to add it, never rewritten: replacing the
  options of a shared field would move the items of the other repositories.
- It links the repository to the Project once, writes `project` in `.claude/senior-mode.json` (`owner`, `number`, `id`,
  `fields`, `home`) and runs the repository steps of `setup github` as usual.
- `project.home` is the repository that holds the duties of the Project as a whole: the one given with `--home`, else the
  one named like the Project's title, else the first repository linked to it. Every member names the same one.
- A Project of another owner is refused, with both owners named. A second run changes nothing.

A repository that already has its own Project moves to the shared one with `--move-items`:

```bash
senior-mode setup github --project 7 --move-items --dry-run   # the mapping, nothing written
senior-mode setup github --project 7 --move-items
```

Its items are added to Project 7 with their Status, Priority, Size and Paths, the repository is linked to Project 7 and
unlinked from its own Project, which is kept (the output has the command that links it again). The shared Project's
fields are never created or rewritten by `--move-items`. See [`setup`](commands.md#setup) for every flag.

Until the served set is delivered, a repository attached to a shared Project is served by its own `serve`, for its own
tickets only: nothing changes there.

## The served set and `serve.scope`

**Planned (#451, #402, #455, #453).** One `serve` per Project, instead of one per repository.

- `serve.scope` is `repo` (the default, today's daemon) or `project`: in `project` scope the daemon started in the anchor
  repository serves every repository of the Project's served set.
- The served set is what the Project lists **and** what agrees to be served: the repository is not archived, has the
  Project's owner, and its `.claude/senior-mode.json` on the default branch names this Project (a two-way handshake).
  `serve.include` and `serve.exclude` (globs of `owner/name`) narrow it. A repository outside it is never started,
  reviewed or merged, even if someone put its issue on the board; the trust gate of
  [ADR 0024](../adr/0024-untrusted-external-input.md) holds in every repository.
- `serve.repos` maps `owner/name` to a clone path on this machine (local layer only); a missing clone is made by
  `gh repo clone` when a ticket of it is first runnable.
- One budget: `autonomy.parallel` and the other ceilings count the whole product, slots come from one machine-wide pool so
  ports never collide, and `autonomy.repoParallel` caps one repository. `serve.repoOrder` breaks ties in the queue.
- A failing repository is held alone: a red main, a lost clone or a breaker in one stops that repository, not the others.

Every key is in [Configuration](configuration.md#multi-repo-keys).

## Naming and filing tickets across repositories

**Planned (#450).** An issue number is unique per repository, not per Project, so a ticket of a shared Project is named by
its ref, `owner/name#n`, wherever a number is accepted (`item get|set`, `ready`, `start`, `--parent`, `--blocked-by`).
`start` and `run` only work on the repository of the current clone. `issue create --repo owner/name` files a ticket in
another adopted repository, adds it to the Project and links it to its parent and blockers whatever their repository.
Without it, every command prints and behaves as today.

## Cross-repo epics

**Planned (#457, #399).** A change that crosses repositories (an API field the web app reads) cannot be one pull request:
the repositories deploy separately and GitHub has no atomic merge. senior-mode delivers it in the only safe order, each
repository deployable at every step: the producer adds the new path while the old one still works, consumers migrate one
by one, the old path is removed last.

- The epic is an issue with sub-issues in two or more repositories and a `## Contract` section (`Name`, `Version`,
  `Compatible`, `Remove when`).
- Sub-issues carry the labels `contract:produce`, `contract:consume` and `contract:remove`, with `blocked-by` edges from
  produce, to every consume, to remove.
- `epics.available` sets when a blocker counts as done: `merged` (the ticket is closed, the default) or `released` (and a
  published release of its repository contains the merge).
- Each ticket is one pull request in its own repository, closing only its own ticket. One that closes another
  repository's ticket is `needs-human`. A failed step stops the steps behind it and nothing else.

## The organization layer

An organization can set its base configuration once. Configuration has five
[layers](configuration.md#layers) and the organization is the third.

**Available (#400).** The layer is read from the organization's own repository, with a file
`<git common dir>/senior-mode/organization.json` of a clone as a machine override; `senior-mode config get` and
`config explain` read it (explain names the layer and its commit), and the repository and local layers override it.
`setup org` ([below](#setup-org)) proposes the one key it knows about, `board.template`, for it.

- `<owner>/<org.repo>` (default `.github`), directory `org.path` (default `senior-mode`), from its default branch only,
  or from `org.ref` when the repository pins one. A pull request or another branch is never read. Its `config.json`
  is the base configuration; `overrides/`, and `knowledge/`, `adr/` and `vision.md` that the briefing and `check` use,
  are planned (#459).
- One conditional read at most every 10 minutes (an hour for `serve`), cached in
  `${XDG_CACHE_HOME:-~/.cache}/senior-mode/org/<owner>/<sha>/`. GitHub unreachable: the last good copy, named by one line
  `org layer: cached <sha>, <age>`; no copy: an empty layer. A missing repository or directory is an empty layer,
  checked again after an hour. Reading never fails a command.
- `org.inherit: false` turns the read off. The `org.*` keys are read from the repository and local layers only.

**Planned (#735).** What the organization may and may not set:

- Commands do not inherit: `commands`, `checks`, `agent.command`, `slot`, `slotUp`, `slotDown` and `notify.webhook` from
  the organization are ignored unless the repository lists the key in `org.allowExec`. Machine keys (`serve.repos`,
  `serve.scope`) do not inherit either.
- Guards only tighten: `protected`, `secrets` and `envGuard.forbidden` are the union of the layers. The locked safety
  base is not liftable by the organization at all.

## `setup org`

**Available.** Prepares an organization once, for the template Project that `setup github` copies:

```bash
senior-mode setup org acme                  # dry run: prints what it would do, changes nothing
senior-mode setup org acme --apply          # copies the template, marks it as an organization template
senior-mode setup org acme --print-ruleset  # JSON of an organization ruleset, for an administrator to apply
```

- For a user account, which has no template Projects, it says so and exits 0.
- With `--apply` it copies the plugin's template Project into the organization and calls `markProjectV2AsTemplate` on the
  copy, once: a rerun changes nothing.
- It then offers `board.template: <the organization's template id>` for the organization layer, as a pull request on
  `<owner>/.github` (branch `chore/senior-mode-org`, file `senior-mode/config.json`), never a push to the default branch.
  When that repository does not exist it prints the file to add and creates nothing.
- A token without the `project` scope, or a role that cannot do it, is named and nothing changes.
- `--print-ruleset` prints the five rules of the repository ruleset (`deletion`, `non_fast_forward`,
  `required_linear_history`, `pull_request` with `rebase`, `required_status_checks` with the three `senior-mode/*`
  contexts) as an organization ruleset. senior-mode never creates, edits or deletes an organization ruleset.

**Planned (#738).** `setup github` will read the effective rules of the default branch, create the repository ruleset with
only the rules an organization ruleset does not already provide, and report under `## Not mapped` the rules it cannot
satisfy (a required approving review, a merge method that excludes `rebase`). In such a repository the daemon would not
merge.

## `status --all`

**Planned (#403).** One report for every repository of the served set, from any clone, reading GitHub only:

```bash
senior-mode status --all
senior-mode status --all --owner acme   # every adopted repository of the owner, whatever its Project
```

Three sections: the budget (sessions over `autonomy.parallel`, launches in the last hour, the usage band and every hold
with its scope), one queue of decisions that wait for a person (with refs, ages and the action, urgent first), and one
line per repository. `--json` carries `budget`, `decisions` and `repos`. A repository that cannot be read is one line
and the exit code stays 0. Without `--all`, `status` is unchanged.

## Configuration keys

The new keys of this page are all optional, and every one has its row in
[Configuration](configuration.md#multi-repo-keys): `serve.scope`, `serve.include`, `serve.exclude`, `serve.repos`,
`serve.repoOrder`, `autonomy.repoParallel`, `epics.available`, `org.inherit`, `org.repo`, `org.path`, `org.ref`,
`org.allowExec` and `project.home`. Only `project.home` and the `org.*` keys but `org.allowExec` are read today.
